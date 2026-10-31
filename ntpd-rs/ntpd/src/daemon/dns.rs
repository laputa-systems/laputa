use std::net::SocketAddr;

#[cfg(feature = "srv")]
use hickory_resolver::{
    TokioResolver,
    net::NetError,
    proto::rr::{IntoName, Name, RData, Record, rdata::SRV},
};
use tokio::net::lookup_host;

use crate::daemon::config::NormalizedAddress;

// We keep the resolver globally to avoid reloading its configuration constantly.
#[cfg(feature = "srv")]
static RESOLVER: std::sync::OnceLock<TokioResolver> = std::sync::OnceLock::new();

pub(crate) struct KeResolutionResult {
    pub(crate) addr: SocketAddr,
    pub(crate) srv_record_name: Option<String>,
}

#[cfg(not(feature = "srv"))]
pub(crate) async fn resolve_ke(
    addr: &NormalizedAddress,
) -> Result<impl Iterator<Item = KeResolutionResult>, std::io::Error> {
    let lookup_result = lookup_host((addr.server_name.as_str(), addr.port))
        .await?
        .map(|addr| KeResolutionResult {
            addr,
            srv_record_name: None,
        });

    Ok(lookup_result)
}

#[cfg(feature = "srv")]
pub(crate) async fn resolve_ke(
    addr: &NormalizedAddress,
) -> Result<impl Iterator<Item = KeResolutionResult>, std::io::Error> {
    // Kludge allowing us to return two types of iterator.
    enum Either<A, B> {
        A(A),
        B(B),
    }

    impl<A: Iterator<Item = KeResolutionResult>, B: Iterator<Item = KeResolutionResult>> Iterator
        for Either<A, B>
    {
        type Item = KeResolutionResult;

        fn next(&mut self) -> Option<Self::Item> {
            match self {
                Either::A(a) => a.next(),
                Either::B(b) => b.next(),
            }
        }
    }

    // First try looking up SRV records
    if let Ok(srv_names) = resolve_srv(format!("_ntske._tcp.{}", addr.server_name)).await {
        let mut result = vec![];
        for name in srv_names.into_iter().map(|v| v.to_ascii()) {
            if let Ok(lookup) = lookup_host((name.as_str(), 4460)).await {
                result.extend(lookup.map(|addr| KeResolutionResult {
                    addr,
                    srv_record_name: Some(name.clone()),
                }));
            }
        }
        if !result.is_empty() {
            return Ok(Either::A(result.into_iter()));
        }
    }

    // Otherwise do a direct name lookup
    let lookup_result = lookup_host((addr.server_name.as_str(), addr.port))
        .await?
        .map(|addr| KeResolutionResult {
            addr,
            srv_record_name: None,
        });

    Ok(Either::B(lookup_result))
}

#[cfg(feature = "srv")]
fn secure_srv_records<'a>(
    answers: impl Iterator<Item = &'a Record>,
) -> impl Iterator<Item = &'a SRV> {
    answers.filter_map(|record| {
        if !record.proof.is_secure() {
            return None;
        }
        match &record.data {
            RData::SRV(srv) => Some(srv),
            _ => None,
        }
    })
}

#[cfg(feature = "srv")]
async fn resolve_srv<N: IntoName>(name: N) -> Result<Vec<Name>, NetError> {
    use crate::daemon::exitcode;
    use rand::Rng;
    use std::process::exit;

    let resolver = RESOLVER.get_or_init(|| {
        let mut builder = match TokioResolver::builder_tokio() {
            Ok(builder) => builder,
            Err(e) => {
                // Abort when the resolver configuration cannot be loaded
                // trying anything else is madness when the system we run
                // on is this broken.
                tracing::error!("Could not load resolver configuration, aborting: {e}.");
                exit(exitcode::CONFIG);
            }
        };
        builder.options_mut().validate = true;
        match builder.build() {
            Ok(resolver) => resolver,
            Err(e) => {
                tracing::error!("Could not build resolver, aborting: {e}.");
                exit(exitcode::CONFIG);
            }
        }
    });

    let lookup_result = resolver.srv_lookup(name).await?;

    // Unfortunately, hickory doesn't order the results for us apropriately, so we need
    // to do this ourselves. See also https://github.com/hickory-dns/hickory-dns/issues/3440
    //
    // For this, we generate a list of all valid results, augmented by a value equal to
    // T^(1/w) where w is the weight of the entry, and T a uniform random variable
    // between 0 and 1. Sorting by these values in increasing order gives a random order
    // respecting the weighting, since independent uniform random X and Y both between 0
    // and 1, the probability X^(1/n) > Y^(1/m) is m/(n+m), which is exactly the chance
    // that the item with weight m should appear before the item with weight n. (Note,
    // this can be checked by calculating the area under the implicit curve
    // x=t^(1/n), y=t^(1/m) in the unit square)
    let mut items: Vec<_> = secure_srv_records(lookup_result.answers().iter())
        .map(|v| {
            (
                if v.weight != 0 {
                    rand::thread_rng()
                        .r#gen::<f64>()
                        .powf(1.0 / (f64::from(v.weight)))
                } else {
                    // Guarantee 0 weight items end up last within their priority group
                    2.0 + rand::thread_rng().r#gen::<f64>()
                },
                v,
            )
        })
        .collect();

    // Now all that remains to be done is sorting the items by first priority and then
    // the generated random value, and we get an ordering respecting RFC2782.
    items.sort_by(|a, b| {
        a.1.priority
            .cmp(&b.1.priority)
            .then(f64::total_cmp(&a.0, &b.0))
    });

    Ok(items.into_iter().map(|v| &v.1.target).cloned().collect())
}

#[cfg(all(test, not(feature = "srv")))]
mod direct_tests {
    use std::net::SocketAddr;

    use super::*;
    use crate::daemon::config::NormalizedAddress;

    #[tokio::test]
    async fn no_srv_profile_resolves_direct_hostnames() {
        let resolved: Vec<KeResolutionResult> =
            resolve_ke(&NormalizedAddress::new_from_parts("127.0.0.1", 4460))
                .await
                .unwrap()
                .collect();

        assert_eq!(resolved.len(), 1);
        assert_eq!(
            resolved[0].addr,
            SocketAddr::from(([127, 0, 0, 1], 4460))
        );
        assert_eq!(resolved[0].srv_record_name, None);
    }
}

#[cfg(all(test, feature = "srv"))]
mod tests {
    use super::*;
    use hickory_resolver::proto::{dnssec::Proof, rr::rdata::A};

    fn srv_record(name: &str, priority: u16, proof: Proof) -> Record {
        let mut record = Record::from_rdata(
            Name::from_ascii(name).unwrap(),
            60,
            RData::SRV(SRV::new(
                priority,
                10,
                4460,
                Name::from_ascii("nts.example.com.").unwrap(),
            )),
        );
        record.proof = proof;
        record
    }

    #[test]
    fn secure_srv_filter_accepts_secure_rejects_insecure() {
        let secure = srv_record("secure.example.com.", 10, Proof::Secure);
        let insecure = srv_record("insecure.example.com.", 5, Proof::Insecure);
        let bogus = srv_record("bogus.example.com.", 1, Proof::Bogus);
        let mut non_srv = Record::from_rdata(
            Name::from_ascii("other.example.com.").unwrap(),
            60,
            RData::A(A::new(192, 0, 2, 1)),
        );
        non_srv.proof = Proof::Secure;

        let targets: Vec<Name> =
            secure_srv_records([&secure, &insecure, &bogus, &non_srv].into_iter())
                .map(|srv| srv.target.clone())
                .collect();

        assert_eq!(targets, vec![Name::from_ascii("nts.example.com.").unwrap()]);
    }
}
