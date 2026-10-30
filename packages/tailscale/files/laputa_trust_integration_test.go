package tls

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

func TestLaputaTLSConnections(t *testing.T) {
	if os.Getenv("LAPUTA_TRUST_TEST_CONTAINER") != "1" {
		t.Skip("requires an isolated /etc/laputa")
	}
	const policy = "/etc/laputa/trust-policy"
	if err := os.MkdirAll("/etc/laputa", 0755); err != nil {
		t.Fatal(err)
	}
	defer os.Remove(policy)
	read := func(path string) []byte {
		b, err := os.ReadFile("/fixtures/tls/" + path)
		if err != nil { t.Fatal(err) }
		return b
	}
	if err := os.Remove(policy); err != nil && !os.IsNotExist(err) { t.Fatal(err) }
	leaf, _ := pem.Decode(read("ee-cross.crt"))
	unrelated, _ := pem.Decode(read("control-inter.crt"))
	key := read("ee-cross.key")
	intermediate, _ := pem.Decode(read("inter-r1.crt"))
	blockedCert, err := x509.ParseCertificate(intermediate.Bytes)
	if err != nil { t.Fatal(err) }
	digest := sha256.Sum256(blockedCert.RawSubjectPublicKeyInfo)
	activePolicy := []byte(fmt.Sprintf("laputa-trust-policy-v1\ngeneration 1\nblocked-spki-sha256 %x\n", digest))
	type insecureClient struct { addr string; config *Config }
	var clients []insecureClient
	connect := func(client insecureClient) (bool, error) {
		raw, err := net.DialTimeout("tcp", client.addr, 5*time.Second)
		if err != nil { return false, err }
		defer raw.Close()
		raw.SetDeadline(time.Now().Add(5*time.Second))
		conn := Client(raw, client.config)
		if err := conn.Handshake(); err != nil { return false, err }
		resumed := conn.ConnectionState().DidResume
		var b [1]byte
		_, err = conn.Read(b[:])
		return resumed, err
	}
	for _, withUnrelated := range []bool{false, true} {
		certs := pem.EncodeToMemory(leaf)
		if withUnrelated { certs = append(certs, pem.EncodeToMemory(unrelated)...) }
		serverCert, err := X509KeyPair(certs, key)
		if err != nil { t.Fatal(err) }
		for _, version := range []uint16{VersionTLS12, VersionTLS13} {
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil { t.Fatal(err) }
			defer listener.Close()
			serverConfig := &Config{Certificates: []Certificate{serverCert}, MinVersion: version, MaxVersion: version}
			go func() {
				for {
					raw, err := listener.Accept()
					if err != nil { return }
					go func() {
						defer raw.Close()
						raw.SetDeadline(time.Now().Add(5*time.Second))
						conn := Server(raw, serverConfig)
						if conn.Handshake() == nil { conn.Write([]byte("x")) }
					}()
				}
			}()
			client := insecureClient{addr: listener.Addr().String(), config: &Config{InsecureSkipVerify: true, ServerName: "127.0.0.1", MinVersion: version, MaxVersion: version, ClientSessionCache: NewLRUClientSessionCache(2)}}
			if _, err := connect(client); err != nil { t.Fatalf("absent policy insecure baseline: %v", err) }
			resumed, err := connect(client)
			if err != nil || !resumed { t.Fatalf("absent policy insecure resume: %v, resumed=%v", err, resumed) }
			clients = append(clients, client)
		}
	}
	if err := os.WriteFile(policy, activePolicy, 0644); err != nil { t.Fatal(err) }
	for _, client := range clients {
		if _, err := connect(client); err == nil || !strings.Contains(err.Error(), "requires certificate verification") { t.Fatalf("insecure cached session: %v", err) }
		client.config.ClientSessionCache = nil
		if _, err := connect(client); err == nil || !strings.Contains(err.Error(), "requires certificate verification") { t.Fatalf("insecure fresh session: %v", err) }
		client.config.LaputaVerify = true
		client.config.RootCAs = x509.NewCertPool()
		if !client.config.RootCAs.AppendCertsFromPEM(read("cross-r1.crt")) { t.Fatal("root certificate") }
		if _, err := connect(client); err == nil || !strings.Contains(err.Error(), "certificate verification failed") { t.Fatalf("incomplete issuer chain: %v", err) }
		trustedLeaf, err := x509.ParseCertificate(leaf.Bytes)
		if err != nil { t.Fatal(err) }
		client.config.RootCAs = x509.NewCertPool()
		client.config.RootCAs.AddCert(trustedLeaf)
		client.config.InsecureSkipVerify = false
		if _, err := connect(client); err != nil { t.Fatalf("directly trusted leaf: %v", err) }
	}
	for _, chain := range []string{"control", "cross-r1", "cross-r2"} {
		certPEM := read("chain-" + chain + ".pem")
		key := "ee-cross.key"
		if chain == "control" { key = "ee-control.key" }
		keyPEM := read(key)
		serverCert, err := X509KeyPair(certPEM, keyPEM)
		if err != nil { t.Fatal(err) }
		intermediate, _ := pem.Decode(read("inter-r1.crt"))
		cert, err := x509.ParseCertificate(intermediate.Bytes)
		if err != nil { t.Fatal(err) }
		digest := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
		blocked := []byte(fmt.Sprintf("laputa-trust-policy-v1\ngeneration 1\nblocked-spki-sha256 %x\n", digest))
		roots := x509.NewCertPool()
		root := chain
		if chain == "control" { root = "cross-r1" }
		if !roots.AppendCertsFromPEM(read(root + ".crt")) { t.Fatal("root certificate") }
		for _, version := range []uint16{VersionTLS12, VersionTLS13} {
			t.Run(fmt.Sprintf("%s-%x", chain, version), func(t *testing.T) {
				listener, err := net.Listen("tcp", "127.0.0.1:0")
				if err != nil { t.Fatal(err) }
				defer listener.Close()
				serverConfig := &Config{Certificates: []Certificate{serverCert}, MinVersion: version, MaxVersion: version}
				go func() {
					for {
						raw, err := listener.Accept()
						if err != nil { return }
						go func() {
							defer raw.Close()
							raw.SetDeadline(time.Now().Add(5 * time.Second))
							conn := Server(raw, serverConfig)
							if conn.Handshake() == nil { conn.Write([]byte("x")) }
						}()
					}
				}()
				cfg := &Config{RootCAs: roots, ServerName: "127.0.0.1", MinVersion: version, MaxVersion: version, ClientSessionCache: NewLRUClientSessionCache(2)}
				resumed := false
				connect := func(config *Config) error {
					raw, err := net.DialTimeout("tcp", listener.Addr().String(), 5*time.Second)
					if err != nil { return err }
					defer raw.Close()
					raw.SetDeadline(time.Now().Add(5 * time.Second))
					conn := Client(raw, config)
					if err := conn.Handshake(); err != nil { return err }
					resumed = conn.ConnectionState().DidResume
					var b [1]byte
					_, err = conn.Read(b[:])
					return err
				}
				if err := os.Remove(policy); err != nil && !os.IsNotExist(err) { t.Fatal(err) }
				if err := os.WriteFile(policy, []byte("laputa-trust-policy-v1\ngeneration 1\n"), 0644); err != nil { t.Fatal(err) }
				if err := connect(cfg); err != nil { t.Fatalf("baseline: %v", err) }
				if _, ok := cfg.ClientSessionCache.Get("127.0.0.1"); !ok { t.Fatal("session was not cached") }
				if err := os.WriteFile(policy, blocked, 0644); err != nil { t.Fatal(err) }
				if chain == "control" {
					if err := connect(cfg); err != nil { t.Fatalf("control under policy: %v", err) }
					if !resumed { t.Fatal("control session did not resume") }
					manual := cfg.Clone()
					manual.ClientSessionCache = nil
					manual.InsecureSkipVerify = true
					manual.LaputaVerify = true
					called := false
					manual.VerifyConnection = func(ConnectionState) error { called = true; return nil }
					if err := connect(manual.Clone()); err != nil || !called { t.Fatalf("verified callback control: %v, called=%v", err, called) }
					manual.RootCAs = x509.NewCertPool()
					called = false
					if err := connect(manual); err == nil || called { t.Fatalf("untrusted callback control: %v, called=%v", err, called) }
					if _, ok := cfg.ClientSessionCache.Get("127.0.0.1"); !ok { t.Fatal("resumed session was not cached") }
					if err := os.Remove(policy); err != nil { t.Fatal(err) }
					if err := connect(cfg); err == nil || !strings.Contains(err.Error(), "cannot read Laputa trust policy") { t.Fatalf("deleted policy cached session: %v", err) }
					cfg.ClientSessionCache = nil
					if err := connect(cfg); err == nil || !strings.Contains(err.Error(), "cannot read Laputa trust policy") { t.Fatalf("deleted policy fresh session: %v", err) }
					if err := os.WriteFile(policy, blocked, 0644); err != nil { t.Fatal(err) }
					cfg.RootCAs = x509.NewCertPool()
					if err := connect(cfg); err == nil { t.Fatal("accepted omitted root") }
					cfg.RootCAs = roots
					if err := os.Remove(policy); err != nil { t.Fatal(err) }
					if err := os.Symlink("/missing-policy", policy); err != nil { t.Fatal(err) }
					if err := connect(cfg); err == nil { t.Fatal("accepted dangling policy symlink") }
					return
				}
				if err := connect(cfg); err == nil { t.Fatal("accepted blocked cached session") }
				cfg.ClientSessionCache = nil
				if err := connect(cfg); err == nil { t.Fatal("accepted blocked certificate") }
				cfg.InsecureSkipVerify = true
				if err := connect(cfg); err == nil { t.Fatal("accepted blocked certificate with verification disabled") }
				if err := os.WriteFile(policy, []byte("bad\n"), 0644); err != nil { t.Fatal(err) }
				if err := connect(cfg); err == nil { t.Fatal("accepted malformed policy") }
			})
		}
	}
}

func TestLaputaPolicyRemoval(t *testing.T) {
	if os.Getenv("LAPUTA_TRUST_TEST_CONTAINER") != "1" { t.Skip("requires an isolated /etc/laputa") }
	const policy = "/etc/laputa/trust-policy"
	if err := os.WriteFile(policy, []byte("laputa-trust-policy-v1\ngeneration 1\n"), 0644); err != nil { t.Fatal(err) }
	if err := laputaCheckPeer(nil, nil, &Config{}); err != nil { t.Fatal(err) }
	if err := os.Remove(policy); err != nil { t.Fatal(err) }
	if err := laputaCheckPeer(nil, nil, &Config{}); err == nil { t.Fatal("accepted deletion after observing a policy") }
}
