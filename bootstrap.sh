#!/usr/bin/env bash
python3 -m venv .ansible
source .ansible/bin/activate
pip3 install -q --upgrade pip
pip3 install -q 'ansible<12.0.0' 'argcomplete<3.7.0' netaddr
pip3 install -q jmespath --force
pip3 install -q yq
ansible-galaxy collection install ansible.utils --force
ansible-galaxy collection install containers.podman --upgrade

# Bastions have no git identity configured by default, so commits made here fall back to
# root@<hostname>. Apply GIT_COMMITTER_NAME/GIT_COMMITTER_EMAIL from credentials.env, once,
# only if not already set locally — see docs/deploy-mno-rhoai-disconnected.md.
[[ -f credentials.env ]] && source credentials.env
if [[ -n "${GIT_COMMITTER_NAME:-}" && -n "${GIT_COMMITTER_EMAIL:-}" ]] && ! git config --local user.name >/dev/null 2>&1; then
	git config --local user.name "${GIT_COMMITTER_NAME}"
	git config --local user.email "${GIT_COMMITTER_EMAIL}"
	echo "Configured local git identity: ${GIT_COMMITTER_NAME} <${GIT_COMMITTER_EMAIL}>"
fi
