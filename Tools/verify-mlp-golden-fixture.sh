#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

fixture_names=(
  "mlp-v1-golden.json"
  "mlp-v1-device-request-golden.json"
)

local_fixture_dir="${MLP_LOCAL_FIXTURE_DIR:-}"
if [[ -z "$local_fixture_dir" && -n "${MLP_LOCAL_FIXTURE:-}" ]]; then
  local_fixture_dir="$(cd "$(dirname "$MLP_LOCAL_FIXTURE")" && pwd)"
fi
if [[ -z "$local_fixture_dir" ]]; then
  local_candidates=(
    "$repo_root/Packages/MiloKit/Tests/MiloLicenseTests/Fixtures"
    "$repo_root/Tests/unit/SqueakyLicense/Fixtures"
  )
  detected_fixture_dirs=()
  for candidate in "${local_candidates[@]}"; do
    if [[ -f "$candidate/${fixture_names[0]}" ]]; then
      detected_fixture_dirs+=("$candidate")
    fi
  done

  if [[ "${#detected_fixture_dirs[@]}" -gt 1 ]]; then
    echo "Multiple local MLP-v1 fixture directories detected; set MLP_LOCAL_FIXTURE_DIR explicitly." >&2
    printf '  %s\n' "${detected_fixture_dirs[@]}" >&2
    exit 1
  fi
  if [[ "${#detected_fixture_dirs[@]}" -eq 1 ]]; then
    local_fixture_dir="${detected_fixture_dirs[0]}"
  fi
fi

canonical_fixture_dir="${MLP_GOLDEN_FIXTURE_DIR:-}"
if [[ -z "$canonical_fixture_dir" && -n "${MLP_GOLDEN_FIXTURE:-}" ]]; then
  canonical_fixture_dir="$(cd "$(dirname "$MLP_GOLDEN_FIXTURE")" && pwd)"
fi
if [[ -z "$canonical_fixture_dir" ]]; then
  for candidate in \
    "$repo_root/_contract/website/tests/fixtures" \
    "$repo_root/../gonggong-site/tests/fixtures" \
    "$repo_root/../website/tests/fixtures"; do
    if [[ -f "$candidate/${fixture_names[0]}" ]]; then
      canonical_fixture_dir="$candidate"
      break
    fi
  done
fi

if [[ -z "$local_fixture_dir" || ! -d "$local_fixture_dir" ]]; then
  echo "Missing local MLP-v1 fixture directory: $local_fixture_dir" >&2
  exit 1
fi
if [[ -z "$canonical_fixture_dir" || ! -d "$canonical_fixture_dir" ]]; then
  echo "Missing canonical MLP-v1 fixture directory." >&2
  echo "This check compares MiloKit's fixtures against the backend repository that owns the MLP-v1" >&2
  echo "contract. Licensing is out of scope until 1.0 and no repository currently holds it, so this" >&2
  echo "script is dormant and is not run by CI. Set MLP_GOLDEN_FIXTURE_DIR to the contract fixtures" >&2
  echo "when licensing resumes." >&2
  exit 1
fi

for fixture_name in "${fixture_names[@]}"; do
  local_fixture="$local_fixture_dir/$fixture_name"
  canonical_fixture="$canonical_fixture_dir/$fixture_name"

  if [[ ! -f "$local_fixture" ]]; then
    echo "Missing local MLP-v1 fixture: $local_fixture" >&2
    exit 1
  fi
  if [[ ! -f "$canonical_fixture" ]]; then
    echo "Missing canonical MLP-v1 fixture: $canonical_fixture" >&2
    exit 1
  fi

  local_hash="$(shasum -a 256 "$local_fixture" | awk '{print $1}')"
  canonical_hash="$(shasum -a 256 "$canonical_fixture" | awk '{print $1}')"

  if [[ "$local_hash" != "$canonical_hash" ]] || ! cmp -s "$local_fixture" "$canonical_fixture"; then
    echo "MLP-v1 golden fixture drift detected." >&2
    echo "local     $local_hash  $local_fixture" >&2
    echo "canonical $canonical_hash  $canonical_fixture" >&2
    echo "Run npm run contract:fixture:sync from the website repo and rerun app tests." >&2
    exit 1
  fi

  echo "MLP-v1 fixture matches canonical website fixture: $canonical_hash  $fixture_name"
done
