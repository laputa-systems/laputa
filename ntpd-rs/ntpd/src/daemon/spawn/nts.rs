use std::{future::Future, sync::{Arc, Mutex}};

use ntp_proto::{KeyExchangeClient, NtsClientConfig, NtsError, SourceConfig};
use statime_base::{Link, SourceType, StdController};
use tokio::net::TcpStream;
use tracing::warn;

use crate::daemon::config::{NormalizedAddress, NtpAddress};
use crate::daemon::dns::resolve_ke;
use crate::daemon::ntp_source::SourceTask;
use crate::daemon::spawn::{CreationParameters, ntp_link_configs, resolve_single_ntp_server};

use super::super::config::NtsSourceConfig;

use super::{LinkTerminationReason, SpawnFailureReason, Spawner};

pub struct NtsSpawner {
    config: NtsSourceConfig,
    key_exchange_client: Arc<KeyExchangeClient>,
    source_config: SourceConfig,
    state: Arc<Mutex<NtsSpawnerState>>,
}

#[derive(Default)]
struct NtsSpawnerState {
    has_spawned: bool,
}

impl NtsSpawner {
    pub fn new(
        config: NtsSourceConfig,
        source_config: SourceConfig,
    ) -> Result<NtsSpawner, NtsError> {
        let key_exchange_client = Arc::new(KeyExchangeClient::new(&NtsClientConfig {
            certificates: config.certificate_authorities.clone(),
            protocol_version: config.ntp_version,
        })?);

        Ok(NtsSpawner {
            config,
            key_exchange_client,
            source_config,
            state: Arc::default(),
        })
    }
}

// We do resolution and connecting at the same time to deal with problems with either
// ipv4 or ipv6.
async fn resolve_and_connect(config: &NtsSourceConfig) -> Option<(TcpStream, String)> {
    if config.enable_srv_resolution {
        match resolve_ke(&config.address).await {
            Ok(addrs) => {
                let mut last_error = None;
                for addr in addrs {
                    let io = match TcpStream::connect(addr.addr).await {
                        Ok(io) => io,
                        Err(e) => {
                            last_error = Some(e);
                            continue;
                        }
                    };
                    return Some((
                        io,
                        addr.srv_record_name
                            .unwrap_or_else(|| config.address.server_name.clone()),
                    ));
                }

                if let Some(e) = last_error {
                    warn!(error = ?e, "error while attempting key exchange");
                } else {
                    warn!("Unresolvable domain name {}", config.address.server_name);
                }
                None
            }
            Err(e) => {
                warn!(error=?e, "Error trying to resolve ke server domain name.");
                None
            }
        }
    } else {
        let io = match TcpStream::connect((
            config.address.server_name.as_str(),
            config.address.port,
        ))
        .await
        {
            Ok(io) => io,
            Err(e) => {
                warn!(error = ?e, "error while attempting key exchange");
                return None;
            }
        };
        Some((io, config.address.server_name.clone()))
    }
}

async fn timeout_spawn<T>(attempt: impl Future<Output = Result<T, SpawnFailureReason>>) -> Result<T, SpawnFailureReason> {
    match tokio::time::timeout(super::NTS_TIMEOUT, attempt).await {
        Ok(result) => result,
        Err(_) => {
            warn!("timeout while establishing an NTS source");
            Err(SpawnFailureReason::RetryableFailure)
        }
    }
}

impl<TimeController: StdController> Spawner<TimeController> for NtsSpawner
where
    TimeController::LinkConfig: From<statime_algo::LinkConfig>,
    TimeController::TrackedLinkConfig: From<statime_algo::TrackedLinkConfig>,
    TimeController::Link<Arc<TimeController>>: Send + 'static,
{
    fn try_spawn(&mut self) -> super::TrySpawnFuture<TimeController> {
        let state = self.state.clone();
        let config = self.config.clone();
        let source_config = self.source_config;
        let key_exchange_client = self.key_exchange_client.clone();

        Box::new(async move {
            let (addr, protocol_version, nts) = timeout_spawn(async {
                let Some((io, name)) = resolve_and_connect(&config).await else {
                    return Err(SpawnFailureReason::RetryableFailure);
                };

                let key_exchange = match key_exchange_client.exchange_keys(io, name, []).await {
                    Ok(key_exchange) => key_exchange,
                    Err(e) => {
                        warn!(error = ?e, "error while attempting key exchange");
                        return Err(SpawnFailureReason::RetryableFailure);
                    }
                };

                let Some(addr) = resolve_single_ntp_server(NtpAddress(
                    NormalizedAddress::new_from_parts(
                        key_exchange.remote.as_str(),
                        key_exchange.port,
                    ),
                )).await else {
                    return Err(SpawnFailureReason::RetryableFailure);
                };
                Ok((addr, key_exchange.protocol_version, key_exchange.nts))
            }).await?;
            let (link_config, tracked_link_config) = ntp_link_configs();

            Ok(CreationParameters {
                stype: SourceType::Ntp,
                link_config: link_config.into(),
                tracked_link_config: Some(tracked_link_config.into()),
                creator: Box::new(
                    move |controller: TimeController::Link<Arc<TimeController>>,
                          clock,
                          managers| {
                        let link_id = controller.id();
                        let (source, initial_actions) = managers.ntp_manager().new_source(
                            addr,
                            source_config,
                            protocol_version,
                            controller,
                            Some(nts),
                        );

                        state.lock().unwrap().has_spawned = true;

                        SourceTask::spawn(
                            link_id,
                            config.address.to_string(),
                            addr,
                            clock,
                            source,
                            initial_actions,
                            managers.source_observer(),
                        )
                    },
                ),
            })
        })
    }

    fn needs_spawn(&self) -> bool {
        !self.state.lock().unwrap().has_spawned
    }

    fn source_terminated(&mut self, _id: statime_base::LinkId, reason: LinkTerminationReason) {
        if reason != LinkTerminationReason::MustDemobilize {
            self.state.lock().unwrap().has_spawned = false;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{sync::Arc, time::Duration};

    use ntp_proto::{
        KeyExchangeServer, KeySetProvider, NtpVersion, NtsServerConfig, ProtocolVersion, SourceConfig,
        tls_utils,
    };
    use statime_base::{ClockId, Controller, Link};
    use tokio::net::TcpListener;

    use crate::daemon::{
        clock::NtpClockWrapper,
        config::{NormalizedAddress, NtsKeAddress, NtsSourceConfig},
        spawn::{
            CreationParameters, LinkTerminationReason, SpawnFailureReason, Spawner, TestController,
            nts::NtsSpawner,
        },
        system::SystemManagers,
    };

    const TEST_CA: &[u8] = include_bytes!("../../../../ntp-proto/test-keys/testca.pem");
    const TEST_CHAIN: &[u8] = include_bytes!("../../../../ntp-proto/test-keys/end.fullchain.pem");
    const TEST_KEY: &[u8] = include_bytes!("../../../../ntp-proto/test-keys/end.key");

    fn trusting_test_ca() -> Arc<[tls_utils::Certificate]> {
        tls_utils::pemfile::certs(&mut &*TEST_CA)
            .collect::<Result<Arc<_>, _>>()
            .unwrap()
    }

    fn nts_source(
        port: u16,
        certificate_authorities: Arc<[tls_utils::Certificate]>,
    ) -> NtsSourceConfig {
        NtsSourceConfig {
            address: NtsKeAddress(NormalizedAddress::new_from_parts("localhost", port)),
            enable_srv_resolution: false,
            certificate_authorities,
            ntp_version: ProtocolVersion::V4,
        }
    }

    async fn serve_one_key_exchange(listener: TcpListener, ntp_port: u16) {
        let server = KeyExchangeServer::new(NtsServerConfig {
            certificate_chain: tls_utils::pemfile::certs(&mut &*TEST_CHAIN)
                .collect::<Result<Vec<_>, _>>()
                .unwrap(),
            private_key: tls_utils::pemfile::private_key(&mut &*TEST_KEY).unwrap(),
            accepted_versions: vec![NtpVersion::V4],
            server: Some("localhost".into()),
            port: Some(ntp_port),
            pool_authentication_tokens: vec![],
        })
        .unwrap();
        let keyset = KeySetProvider::new(1).get();
        let (socket, _) = listener.accept().await.unwrap();
        let _ = server.handle_connection(socket, keyset.as_ref(), || None::<()>).await;
    }

    #[tokio::test]
    async fn creates_a_source_that_carries_the_negotiated_cookies() {
        #[cfg(feature = "openssl")]
        let _ = rustls_openssl::default_provider().install_default();

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let ke_port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(serve_one_key_exchange(listener, 12345));

        let managers = SystemManagers::test_managers();
        let mut spawner =
            NtsSpawner::new(nts_source(ke_port, trusting_test_ca()), SourceConfig::default())
                .unwrap();

        assert!(<NtsSpawner as Spawner<TestController>>::needs_spawn(&spawner));
        let params: CreationParameters<TestController> =
            Box::into_pin(spawner.try_spawn()).await.unwrap();
        server.await.unwrap();

        let link = TestController::create_tracked_link(
            TestController {},
            ClockId::new(),
            None,
            params.link_config,
            params.tracked_link_config.unwrap(),
        )
        .unwrap();
        let link_id = link.id();
        let handle = (params.creator)(link, NtpClockWrapper::default(), &managers);
        assert!(!<NtsSpawner as Spawner<TestController>>::needs_spawn(&spawner));

        let observed = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let Some(source) = managers.observed_sources().read().unwrap().values().next() {
                    break source.clone();
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        let cookies = observed.nts_cookies.expect("an NTS source reports its cookies");
        assert!((1..=ntp_proto::MAX_COOKIES).contains(&cookies), "{cookies}");
        assert!(observed.address.ends_with(":12345"), "{}", observed.address);

        handle.abort();
        <NtsSpawner as Spawner<TestController>>::source_terminated(
            &mut spawner,
            link_id,
            LinkTerminationReason::NetworkIssue,
        );
        assert!(<NtsSpawner as Spawner<TestController>>::needs_spawn(&spawner));
    }

    #[tokio::test]
    async fn does_not_trust_a_server_without_the_configured_authority() {
        #[cfg(feature = "openssl")]
        let _ = rustls_openssl::default_provider().install_default();

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let ke_port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(serve_one_key_exchange(listener, 12345));

        let mut spawner =
            NtsSpawner::new(nts_source(ke_port, Arc::new([])), SourceConfig::default()).unwrap();

        let result: Result<CreationParameters<TestController>, SpawnFailureReason> =
            Box::into_pin(<NtsSpawner as Spawner<TestController>>::try_spawn(&mut spawner)).await;
        server.await.unwrap();

        assert_eq!(result.err(), Some(SpawnFailureReason::RetryableFailure));
        assert!(<NtsSpawner as Spawner<TestController>>::needs_spawn(&spawner));
    }

    #[tokio::test(start_paused = true)]
    async fn deadline_covers_all_spawn_stages() {
        let attempt = tokio::spawn(super::timeout_spawn(async {
            tokio::time::sleep(Duration::from_secs(4)).await;
            tokio::time::sleep(Duration::from_secs(2)).await;
            Ok::<_, SpawnFailureReason>(())
        }));
        tokio::task::yield_now().await;
        tokio::time::advance(Duration::from_secs(4)).await;
        tokio::task::yield_now().await;
        assert!(!attempt.is_finished());
        tokio::time::advance(Duration::from_secs(1)).await;
        assert_eq!(attempt.await.unwrap(), Err(SpawnFailureReason::RetryableFailure));
    }

    #[tokio::test]
    async fn retries_when_the_key_exchange_server_is_unreachable() {
        let unused = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let ke_port = unused.local_addr().unwrap().port();
        drop(unused);

        let mut spawner =
            NtsSpawner::new(nts_source(ke_port, trusting_test_ca()), SourceConfig::default())
                .unwrap();

        let result: Result<CreationParameters<TestController>, SpawnFailureReason> =
            Box::into_pin(<NtsSpawner as Spawner<TestController>>::try_spawn(&mut spawner)).await;

        assert_eq!(result.err(), Some(SpawnFailureReason::RetryableFailure));
    }
}
