# Build & test
build  :; forge build --sizes
test   :; forge test -vvv

# Utilities
gas-report :; forge test --mp 'test/gas/**'
