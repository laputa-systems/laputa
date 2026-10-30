let url = args[0]
let bundle = fp"/fixtures/tls/{args[1]}.crt"
let verify = args[2] == "verify"
let expected = args[3]
match net.request({method: "GET", url, ca_certificate: bundle, tls_verify: verify, timeout: 10s}) {
  Ok(response) => {
    assert expected == "accept", "policy-forbidden TLS request was accepted"
    assert response.status == 200
    assert response.body.require(Bytes)?.utf8()? == "hello\n"
  },
  Err(problem) => {
    assert expected == "reject", problem.message
    assert "TLS negotiation or certificate validation failed" in problem.message, problem.message
  },
}
