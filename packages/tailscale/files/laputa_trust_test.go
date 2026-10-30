package tls

import "testing"

func TestLaputaTrustPolicy(t *testing.T) {
	valid := "laputa-trust-policy-v1\ngeneration 1\nblocked-spki-sha256 43bffa19d6ef651451f6841e019931e96f6f2eaeff28ab4b6f1ce4576de2717b\n"
	if hashes, err := laputaTrustPolicy([]byte(valid)); err != nil || len(hashes) != 1 {
		t.Fatalf("valid policy: %v, %v", hashes, err)
	}
	for _, body := range []string{
		"", "laputa-trust-policy-v1\ngeneration 1", "laputa-trust-policy-v1\ngeneration 0\n",
		"laputa-trust-policy-v1\ngeneration 01\n", "laputa-trust-policy-v1\ngeneration +1\n",
		"laputa-trust-policy-v1\ngeneration 18446744073709551616\n",
		"laputa-trust-policy-v1\ngeneration 1\nunknown-field x\n",
		"laputa-trust-policy-v1\r\ngeneration 1\r\n",
		valid + "blocked-spki-sha256 43bffa19d6ef651451f6841e019931e96f6f2eaeff28ab4b6f1ce4576de2717b\n",
		"laputa-trust-policy-v1\ngeneration 1\nblocked-spki-sha256 43BFFA19D6EF651451F6841E019931E96F6F2EAEFF28AB4B6F1CE4576DE2717B\n",
	} {
		if _, err := laputaTrustPolicy([]byte(body)); err == nil {
			t.Errorf("accepted malformed policy %q", body)
		}
	}
}
