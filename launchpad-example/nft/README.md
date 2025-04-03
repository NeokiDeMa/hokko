# NFT Example

## Steps

1. Import Launchpad package in Move.toml
   ```toml
   # or if repo will be opened
   # Kiosk = { git = "https://github.com/retwn/hokko-mintpad.git", subdir = "contracts/launchpad", rev = "main" }
   Launchpad = { local = "../../launchpad" }
   ```

2. Publish your package
   ```bash
   sui client publish --json > deploy.json
   ```
3. Call `package::module::new` function to create a `Collection` and obtain `Creator` role.
4. Wait approval from Launchpad `Admin` role.
5. Optionally, add addresses to the whitelist. (through Launchpad package)
6. Optionally, update the collection start timestamps. (through Launchpad package)
7. Optionally, pause or resume the collection. (through Launchpad package)
8. Mint NFTs using the `mint` or `mint_with_kiosk` function. Depending on is kiosk enabled or not.