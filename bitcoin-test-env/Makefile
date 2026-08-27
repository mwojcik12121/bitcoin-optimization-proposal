.PHONY: list scenario1 clean-images

list:
	./run.sh --list

scenario1:
	./run.sh 1

clean-images:
	-docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^bitcoin-env/node0[1-8]:source-' | xargs -r docker image rm
	-docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^bitcoin-env/core-source:' | xargs -r docker image rm
