# =============================================================================
# MediaStack config reader: cfg_read and its cfg_* adapters (sourced by common.sh)
# =============================================================================
# Every input (config path, dotted key, mode, optional default) reaches python
# via argv — never string-formatted into the program text — so a key or path
# with special characters can never corrupt the source. The public cfg_* names
# below are thin adapters over cfg_read; they are kept as separate functions
# because the unit tests stub them by name.
cfg_read() {
    # cfg_read <mode> <key> [default]   — reads $CONFIG_FILE (via argv).
    # default: json mode = fallback JSON; value mode = absent-key fallback
    # (empty string = emit nothing, rc 0).
    python3 - "$CONFIG_FILE" "$@" <<'PY' 2>/dev/null
import sys, json, re, yaml

config_file, mode = sys.argv[1], sys.argv[2]
key = sys.argv[3] if len(sys.argv) > 3 else ""
default = sys.argv[4] if len(sys.argv) > 4 else None

# PyYAML resolves numbers by YAML 1.1: 010 is octal 8, 0x10 is 16, 1:30 is 90.
# Resolve only plain decimal numbers instead, so a number that looks like one of
# those forms stays text and the consumer's own digit check accepts or rejects it.
INT_FLOAT = ("tag:yaml.org,2002:int", "tag:yaml.org,2002:float")

class Loader(yaml.SafeLoader):
    yaml_implicit_resolvers = {
        ch: [(tag, rx) for tag, rx in rules if tag not in INT_FLOAT]
        for ch, rules in yaml.SafeLoader.yaml_implicit_resolvers.items()
    }

Loader.add_implicit_resolver(
    INT_FLOAT[0], re.compile(r"^[-+]?[0-9]+$"), list("-+0123456789"))
Loader.add_implicit_resolver(
    INT_FLOAT[1],
    re.compile(r"^(?:[-+]?(?:[0-9]+\.[0-9]*|\.[0-9]+)(?:[eE][-+][0-9]+)?"
               r"|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$"),
    list("-+.0123456789"))
Loader.add_constructor(INT_FLOAT[0], lambda ld, node: int(ld.construct_scalar(node), 10))

with open(config_file) as f:
    data = yaml.load(f, Loader=Loader)

def walk(root, dotted):
    node = root
    for k in dotted.split('.'):
        node = node[int(k)] if isinstance(node, list) else node[k]
    return node

if mode == "value":
    try:
        node = walk(data, key)
    except (KeyError, IndexError, TypeError):
        if default is None:
            sys.exit(1)
        node = None
    # Absent (or present-but-null) key: with a default, emit it (empty
    # default = emit nothing) and succeed. Without a default, an absent key
    # keeps the non-zero rc; a legitimate null value still prints "None".
    if default is not None and node is None:
        if default:
            print(default)
        sys.exit(0)
    if isinstance(node, list):
        for item in node:
            print(' '.join(str(x) for x in item.values()) if isinstance(item, dict) else item)
    else:
        print(node)
elif mode == "pairs":
    # A null/non-string value (e.g. a blank category path) fails the whole
    # read before anything is printed (rc 1, like the pre-refactor readers'
    # TypeError) — never emit "name:None" for a caller to configure verbatim.
    items = walk(data, key).items()
    if any(not isinstance(val, str) for _, val in items):
        sys.exit(1)
    for name, val in items:
        print(f"{name}:{val}")
elif mode == "json":
    try:
        node = walk(data, key)
    except (KeyError, IndexError, TypeError):
        node = None
    if default is not None and not node:
        print(default)
    elif node is None:
        sys.exit(1)
    else:
        print(json.dumps(node))
elif mode == "indexers":
    for idx in data.get('indexers', []):
        print(idx['id'] + ':' + idx.get('type', 'general'))
elif mode == "jf_libraries":
    for lib in data['jellyfin']['libraries']:
        print(lib['name'] + ':' + lib['type'] + ':' + lib['path'])
else:
    sys.exit("cfg_read: unknown mode " + mode)
PY
}

# Adapters — each pins the mode + key/default so call sites stay unchanged.
# Scalar/leaf read (auto-iterates a list value, e.g. bazarr languages).
cfg_field() { cfg_read value "$1"; }
# Indexer list as id:type pairs (type defaults to "general").
cfg_indexers() { cfg_read indexers ""; }
# quality_profile.<app>_qualities as a JSON array; empty + non-zero rc if absent.
cfg_quality_ids() { cfg_read json "quality_profile.${1}_qualities"; }
# quality_definitions.<app> as a JSON object; {} when the section is absent.
cfg_quality_definitions() { cfg_read json "quality_definitions.$1" '{}'; }
# custom_formats (name→score) as a JSON object; {} when absent.
cfg_custom_format_scores() { cfg_read json custom_formats '{}'; }
# qBittorrent categories as name:path pairs.
cfg_qbt_categories() { cfg_read pairs qbittorrent.categories; }
# Bazarr languages, one per line; empty + rc 0 when the key is absent.
cfg_bazarr_languages() { cfg_read value bazarr.languages ""; }
# Jellyfin libraries as name:type:path.
cfg_jf_libraries() { cfg_read jf_libraries ""; }
