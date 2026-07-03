.PHONY: help build test clean

help:
	@echo "StableVault Project Commands"
	@echo ""
	@echo "Build & Test:"
	@echo "  make build                     - Build contracts"
	@echo "  make test                      - Run all tests"
	@echo "  make coverage-unit             - Get test coverage (LCOV format) from unit tests"
	@echo "  make gas-report                - Get gas report from gas tests"
	@echo "  make clean                     - Clean build artifacts"
	@echo "  make format                    - Format all the solidity files"
	@echo "  make update                    - Update dependencies"
	@echo ""

# Build & test
build  :; forge build --sizes
test   :; forge test -vvv

# Coverage 
coverage-unit :; forge coverage --report lcov --mp 'test/unit/**'

# Utilities
gas-report :; forge test --mp 'test/gas/**'

# Miscellaneous
clean :; forge clean
format :; forge fmt

# Dependencies
update:; forge update

# Smoke tests
# Usage: make smoke ENV=preprod CHAIN=accounting [FLAGS="--summary"]
smoke :; tsx tools/smoke/run.ts --env $(ENV) --chain $(CHAIN) $(FLAGS)
