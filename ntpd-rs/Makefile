.PHONY: lint

lint:
	@rustup component add clippy > /dev/null 2>&1
	cargo clippy --workspace --all-targets -- --deny warnings
