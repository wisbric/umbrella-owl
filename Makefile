.PHONY: deploy-lab dep-update

dep-update:
	helm dep update .

deploy-lab: dep-update
	helm upgrade owl . -n owl -f values.lab.yaml -f values.lab-secrets.yaml
