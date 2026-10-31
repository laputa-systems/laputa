#[cfg(all(feature = "graviola", feature = "aws-lc"))]
compile_error!(
    "the `graviola` TLS provider is mutually exclusive with `aws-lc`; enable exactly one TLS provider"
);

#[cfg(all(feature = "graviola", feature = "openssl"))]
compile_error!(
    "the `graviola` TLS provider is mutually exclusive with `openssl`; enable exactly one TLS provider"
);

#[cfg(not(any(feature = "aws-lc", feature = "openssl", feature = "graviola")))]
compile_error!(
    "no TLS provider selected; enable exactly one of the `aws-lc`, `openssl`, or `graviola` features"
);

mod rustls23_shim {
    pub use rustls23::ClientConfig;
    pub use rustls23::ClientConnection;
    pub use rustls23::ConnectionCommon;
    pub use rustls23::Error;
    pub use rustls23::RootCertStore;
    pub use rustls23::ServerConfig;
    pub use rustls23::ServerConnection;
    pub use rustls23::pki_types::InvalidDnsNameError;
    pub use rustls23::pki_types::ServerName;
    pub use rustls23::server::NoClientAuth;
    pub use rustls23::version::TLS13;

    pub type Certificate = rustls23::pki_types::CertificateDer<'static>;
    pub type PrivateKey = rustls23::pki_types::PrivateKeyDer<'static>;

    pub use rustls_platform_verifier::Verifier as PlatformVerifier;

    pub mod pemfile {
        use rustls23::pki_types::{
            CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, pem::PemObject,
        };

        pub fn certs(
            rd: &mut dyn std::io::BufRead,
        ) -> impl Iterator<Item = Result<CertificateDer<'static>, std::io::Error>> + '_ {
            CertificateDer::pem_reader_iter(rd).map(|item| {
                item.map_err(|err| match err {
                    rustls23::pki_types::pem::Error::Io(error) => error,
                    _ => std::io::Error::new(std::io::ErrorKind::InvalidInput, err.to_string()),
                })
            })
        }

        pub fn private_key(
            rd: &mut dyn std::io::BufRead,
        ) -> Result<PrivateKeyDer<'static>, std::io::Error> {
            PrivateKeyDer::from_pem_reader(rd).map_err(|err| match err {
                rustls23::pki_types::pem::Error::Io(error) => error,
                _ => std::io::Error::new(std::io::ErrorKind::InvalidInput, err.to_string()),
            })
        }

        pub fn pkcs8_private_keys(
            rd: &mut dyn std::io::BufRead,
        ) -> impl Iterator<Item = Result<PrivatePkcs8KeyDer<'static>, std::io::Error>> + '_
        {
            PrivatePkcs8KeyDer::pem_reader_iter(rd).map(|item| {
                item.map_err(|err| match err {
                    rustls23::pki_types::pem::Error::Io(error) => error,
                    _ => std::io::Error::new(std::io::ErrorKind::InvalidInput, err.to_string()),
                })
            })
        }
    }

    pub trait CloneKeyShim {}

    #[cfg(feature = "graviola")]
    fn tls_provider() -> std::sync::Arc<rustls23::crypto::CryptoProvider> {
        std::sync::Arc::new(rustls_graviola::default_provider())
    }

    /// Panics if the selected provider offers no usable cipher suite for the
    /// default protocol versions, which cannot happen for the shipped providers.
    pub fn client_config_builder()
    -> rustls23::ConfigBuilder<rustls23::ClientConfig, rustls23::WantsVerifier> {
        #[cfg(feature = "graviola")]
        {
            ClientConfig::builder_with_provider(tls_provider())
                .with_safe_default_protocol_versions()
                .unwrap()
        }
        #[cfg(not(feature = "graviola"))]
        {
            ClientConfig::builder()
        }
    }

    /// Panics if the selected provider offers no usable cipher suite for the
    /// requested protocol versions, which cannot happen for the shipped providers.
    pub fn client_config_builder_with_protocol_versions(
        versions: &[&'static rustls23::SupportedProtocolVersion],
    ) -> rustls23::ConfigBuilder<rustls23::ClientConfig, rustls23::WantsVerifier> {
        #[cfg(feature = "graviola")]
        {
            ClientConfig::builder_with_provider(tls_provider())
                .with_protocol_versions(versions)
                .unwrap()
        }
        #[cfg(not(feature = "graviola"))]
        {
            ClientConfig::builder_with_protocol_versions(versions)
        }
    }

    /// Panics if the selected provider offers no usable cipher suite for the
    /// default protocol versions, which cannot happen for the shipped providers.
    pub fn server_config_builder()
    -> rustls23::ConfigBuilder<rustls23::ServerConfig, rustls23::WantsVerifier> {
        #[cfg(feature = "graviola")]
        {
            ServerConfig::builder_with_provider(tls_provider())
                .with_safe_default_protocol_versions()
                .unwrap()
        }
        #[cfg(not(feature = "graviola"))]
        {
            ServerConfig::builder()
        }
    }

    /// Panics if the selected provider offers no usable cipher suite for the
    /// requested protocol versions, which cannot happen for the shipped providers.
    pub fn server_config_builder_with_protocol_versions(
        versions: &[&'static rustls23::SupportedProtocolVersion],
    ) -> rustls23::ConfigBuilder<rustls23::ServerConfig, rustls23::WantsVerifier> {
        #[cfg(feature = "graviola")]
        {
            ServerConfig::builder_with_provider(tls_provider())
                .with_protocol_versions(versions)
                .unwrap()
        }
        #[cfg(not(feature = "graviola"))]
        {
            ServerConfig::builder_with_protocol_versions(versions)
        }
    }
}

pub use rustls23_shim::*;
