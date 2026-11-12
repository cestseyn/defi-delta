# defi-delta

Delta-managed option vaults: ERC-7540 vaults on Ethereum L1 that own a Derive v3 account, sell weekly ETH options and delta-hedge with the perp.

| Path | Contents |
|---|---|
| `docs/spec/` | Core specification (start with `docs/spec/README.md`) |
| `contracts/` | L1 contracts (Foundry) |
| `services/` | Off-chain services: strategy, attesters, round processor (Python) |

## Contributing

Commits must be made in UTC (`TZ=UTC git commit ...`); the pre-commit hook in `.githooks/` enforces the repository identity and timezone.
