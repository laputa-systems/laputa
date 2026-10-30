package tls

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
)

func laputaTrustPolicy(data []byte) (map[[32]byte]struct{}, error) {
	invalid := errors.New("tls: invalid Laputa trust policy")
	if len(data) == 0 || len(data) > 1048576 || data[len(data)-1] != '\n' {
		return nil, invalid
	}
	lines := strings.Split(string(data[:len(data)-1]), "\n")
	if len(lines) < 2 || lines[0] != "laputa-trust-policy-v1" {
		return nil, invalid
	}
	generation, ok := strings.CutPrefix(lines[1], "generation ")
	if !ok || len(generation) == 0 || generation[0] == '0' {
		return nil, invalid
	}
	n, err := strconv.ParseUint(generation, 10, 64)
	if err != nil || n == 0 || strconv.FormatUint(n, 10) != generation {
		return nil, invalid
	}
	blocked := make(map[[32]byte]struct{})
	for _, line := range lines[2:] {
		value, ok := strings.CutPrefix(line, "blocked-spki-sha256 ")
		if !ok || len(value) != 64 || value != strings.ToLower(value) {
			return nil, invalid
		}
		var hash [32]byte
		if _, err := hex.Decode(hash[:], []byte(value)); err != nil {
			return nil, invalid
		}
		if _, ok := blocked[hash]; ok {
			return nil, invalid
		}
		blocked[hash] = struct{}{}
	}
	return blocked, nil
}

var laputaPolicySeen atomic.Bool

func laputaCheckPeer(certs []*x509.Certificate, chains [][]*x509.Certificate, config *Config) error {
	const path = "/etc/laputa/trust-policy"
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			if _, statErr := os.Lstat(path); errors.Is(statErr, os.ErrNotExist) && !laputaPolicySeen.Load() {
				return nil
			}
		}
		laputaPolicySeen.Store(true)
		return errors.New("tls: cannot read Laputa trust policy")
	}
	laputaPolicySeen.Store(true)
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 1048577))
	if err != nil {
		return errors.New("tls: cannot read Laputa trust policy")
	}
	blocked, err := laputaTrustPolicy(data)
	if err != nil {
		return err
	}
	if config.InsecureSkipVerify {
		if !config.LaputaVerify || len(certs) == 0 || config.ServerName == "" {
			return errors.New("tls: Laputa trust policy requires certificate verification")
		}
		opts := x509.VerifyOptions{
			DNSName: config.ServerName,
			CurrentTime: config.time(),
			Intermediates: x509.NewCertPool(),
		}
		for _, cert := range certs[1:] {
			opts.Intermediates.AddCert(cert)
		}
		chains, err = certs[0].Verify(opts)
		if err != nil && config.RootCAs != nil {
			opts.Roots = config.RootCAs
			chains, err = certs[0].Verify(opts)
		}
		if err != nil {
			return errors.New("tls: Laputa trust policy certificate verification failed: " + err.Error())
		}
	}
	chains = append(chains, certs)
	for _, chain := range chains {
		for _, cert := range chain {
			if _, ok := blocked[sha256.Sum256(cert.RawSubjectPublicKeyInfo)]; ok {
				return errors.New("tls: certificate blocked by Laputa trust policy")
			}
		}
	}
	return nil
}
