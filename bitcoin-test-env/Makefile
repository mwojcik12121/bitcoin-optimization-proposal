.PHONY: list scenario1 scenario2 scenario3 clean-images

list:
	./run.sh --list

scenario1:
	./run.sh 1

scenario2:
	./run.sh 2

scenario3:
	./run.sh 3

clean-images:
	-docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^bitcoin-env/node(01|02|03|04):source-' | xargs -r docker image rm
	-docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^bitcoin-env/core-source:' | xargs -r docker image rm
