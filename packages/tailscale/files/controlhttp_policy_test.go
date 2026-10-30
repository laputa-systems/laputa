package controlhttp

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestLaputaControlHTTPPolicy(t *testing.T) {
	if os.Getenv("LAPUTA_TRUST_TEST_CONTAINER") != "1" { t.Skip("requires an isolated /etc/laputa") }
	t.Setenv("SSL_CERT_FILE", "/fixtures/tls/cross-r1.crt")
	t.Setenv("SSL_CERT_DIR", "/fixtures/no-certificate-directory")
	read := func(name string) []byte {
		data, err := os.ReadFile("/fixtures/tls/" + name)
		if err != nil { t.Fatal(err) }
		return data
	}
	intermediate, _ := pem.Decode(read("inter-r1.crt"))
	cert, err := x509.ParseCertificate(intermediate.Bytes)
	if err != nil { t.Fatal(err) }
	hash := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
	policy := []byte(fmt.Sprintf("laputa-trust-policy-v1\ngeneration 1\nblocked-spki-sha256 %x\n", hash))
	if err := os.MkdirAll("/etc/laputa", 0755); err != nil { t.Fatal(err) }
	if err := os.WriteFile("/etc/laputa/trust-policy", policy, 0644); err != nil { t.Fatal(err) }
	defer os.Remove("/etc/laputa/trust-policy")
	for _, entry := range []struct{ chain, key, root, outcome string }{
		{"control", "ee-control", "cross-r1", "404 Not Found"},
		{"cross-r1", "ee-cross", "cross-r1", "certificate blocked by Laputa trust policy"},
		{"cross-r2", "ee-cross", "cross-r2", "certificate blocked by Laputa trust policy"},
		{"control", "ee-control", "cross-r2", "404 Not Found"},
		{"cross-r2", "ee-cross", "cross-r1", "certificate verification failed"},
	} {
		t.Run(entry.chain+"-"+entry.root, func(t *testing.T) {
			serverCert, err := tls.X509KeyPair(read("chain-"+entry.chain+".pem"), read(entry.key+".key"))
			if err != nil { t.Fatal(err) }
			var reached atomic.Bool
			server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				reached.Store(true)
				http.NotFound(w, nil)
			}))
			server.Config.ErrorLog = log.New(io.Discard, "", 0)
			server.TLS = &tls.Config{Certificates: []tls.Certificate{serverCert}}
			server.StartTLS()
			defer server.Close()
			roots := x509.NewCertPool()
			if !roots.AppendCertsFromPEM(read(entry.root+".crt")) { t.Fatal("root certificate") }
			target, err := url.Parse(server.URL)
			if err != nil { t.Fatal(err) }
			dialer := &Dialer{ExtraRootCAs: roots, proxyFunc: func(*http.Request) (*url.URL, error) { return nil, nil }}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			conn, err := dialer.tryURLUpgrade(ctx, target, netip.MustParseAddr("127.0.0.1"), "", nil)
			if conn != nil { conn.Close() }
			if err == nil || !strings.Contains(err.Error(), entry.outcome) { t.Fatalf("unexpected outcome: %v", err) }
			if reached.Load() != (entry.chain == "control") { t.Fatalf("HTTP reached: %v", reached.Load()) }
		})
	}
}
