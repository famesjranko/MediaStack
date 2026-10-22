# Owns: finding the Compose project name and the anonymous Docker volumes that
# belong to this project's containers.
# Sources: the docker CLI. Shared by the launcher (Stop all) and the teardown in
# scripts/setup/checks/destroy.sh (wipe and uninstall).

_compose_project_name() {
    docker compose --profile "*" config --format json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null
}

# Names of the anonymous volumes mounted by this project's containers (running
# or stopped). Docker labels an anonymous volume only with
# com.docker.volume.anonymous, never with the project, so the container is the
# only link to it: collect before the containers are removed. A volume the user
# created is not anonymous and is never listed, even when mounted.
#
# Why callers collect and remove these themselves instead of trusting
# `down --volumes`: when `docker compose up` recreates a container (a changed
# .env value such as the beszel agent key), Compose re-mounts the old anonymous
# volume by name. Docker treats a named mount as the user's, so `down --volumes`
# then leaves it behind, unattached and unlabelled by the project.
project_anonymous_volumes() {
    local project="$1" cid mounted anon
    anon=$(docker volume ls -q --filter label=com.docker.volume.anonymous 2>/dev/null) || return 0
    [[ -n "$anon" ]] || return 0
    while IFS= read -r cid; do
        [[ -n "$cid" ]] || continue
        mounted=$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' "$cid" 2>/dev/null) || continue
        grep -Fxf <(printf '%s\n' "$anon") <<<"$mounted" || true
    done < <(docker ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null)
}
