
shellcheck:
	@./hack/shellcheck.sh

yamlfmt:
	@./hack/yamlfmt.sh

verify:
	VALIDATE_ONLY=true $(MAKE) shellcheck
	VALIDATE_ONLY=true $(MAKE) yamlfmt

install-pre-commit:
	@echo "Installing pre-commit hook..."
	@ln -sf ../../hack/pre-commit .git/hooks/pre-commit
	@echo "Pre-commit hook installed successfully!"

uninstall-pre-commit:
	@echo "Uninstalling pre-commit hook..."
	@rm -f .git/hooks/pre-commit
	@echo "Pre-commit hook uninstalled successfully!"
