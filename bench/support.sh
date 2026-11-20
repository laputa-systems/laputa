set -u
mode=$1
shift
resolve_image() {
  image=$("${BENCH_XSH:?}" seed/images.xsh -- ref --arch x86_64) || { echo "preflight: cannot resolve the pinned package-tools image"; exit 1; }
}
seed=${BENCH_SEED:-.out/seed/x86_64}
xsh_root=${BENCH_XSH_ROOT:?}
root=$(pwd -P)
package_names=(baselayout musl linux-headers)
package_key() {
  local name=$1 best= best_time=0 file id time
  for file in .out/artifacts/x86_64/v2/sha256/*/artifact.json; do
    id=$(jaq -r '.package_id' "$file") || continue
    [[ $id =~ ^$name-[0-9] ]] || continue
    time=$(stat -c %Y "$file")
    if (( time > best_time )); then best=${file%/artifact.json}; best=${best##*/}; best_time=$time; fi
  done
  [[ -n $best ]] && printf '%s\n' "$best"
}
resolve_packages() {
  local name key
  packages=()
  for name in "${package_names[@]}"; do
    key=$(package_key "$name") || { echo "preflight: no built artifact for package $name"; exit 1; }
    packages+=("$key")
  done
}
products=(xsh xshi xsht core.tar.xz)
verdict() {
  local ready=$1 value=$2 anchor=$3 tolerance=$4
  if [[ $ready != 0 ]]; then echo 'inconclusive: host busy'
  elif [[ $anchor == - ]]; then echo 'inconclusive: no anchor'
  elif (( value <= anchor + tolerance )); then echo 'within budget'
  else echo regression
  fi
}
seed_check() {
  local manifest=$seed/manifest.json commit dirty pin name expected actual failed=0
  if [[ ! -f $manifest ]]; then echo "preflight: missing seed manifest $manifest"; return 1; fi
  commit=$(jaq -er '.xsh_commit | strings' "$manifest") || return 1
  dirty=$(jaq -er '.xsh_dirty | tostring' "$manifest") || return 1
  pin=$(awk -F= '$1 == "XSH_COMMIT" {print $2}' infra/asterinas/inputs.lock)
  if [[ $dirty != false ]] || ! git -C "$xsh_root" merge-base --is-ancestor "$pin" "$commit"; then
    echo "preflight: stale seed commit=$commit dirty=$dirty pin=$pin"; failed=1
  fi
  for name in "${products[@]}"; do
    expected=$(jaq -er --arg name "$name" '.files[$name] | strings' "$manifest") || { echo "preflight: missing manifest entry $name"; failed=1; continue; }
    if [[ ! -f $seed/$name ]]; then echo "preflight: missing seed product $name"; failed=1; continue; fi
    actual=$(sha256sum "$seed/$name") || return 1; actual=${actual%% *}
    if [[ $expected != "$actual" ]]; then echo "preflight: stale seed product $name"; failed=1; fi
  done
  return "$failed"
}
children_check() {
  local file pid found=0
  shopt -s nullglob
  for file in .work/bench/*.pid; do
    read -r pid < "$file" || return 1
    [[ $pid =~ ^[0-9]+$ ]] || { echo "preflight: invalid pidfile $file"; found=1; continue; }
    if ps -eo pgid=,stat= | awk -v pgid="$pid" '$1 == pgid && $2 !~ /^Z/ {found=1} END {exit !found}'; then
      echo "preflight: surviving child process group $pid ($file)"; found=1
    fi
  done
  return "$found"
}
case $mode in
  verdict) verdict "$@" ;;
  oracle) [[ $1 =~ ^[1-9][0-9]*$ ]] && jaq -e '[.nodes[] | select(.name == "baselayout")] | length > 0' "$2" >/dev/null ;;
  check)
    failed=0
    children_check || failed=1
    if command -v docker >/dev/null; then
      containers=$(docker ps --filter label=laputa.bench --format '{{.ID}} {{.Names}}') || { echo 'preflight: cannot inspect containers'; failed=1; containers=; }
      if [[ -n $containers ]]; then echo "preflight: surviving benchmark container $containers"; failed=1; fi
    fi
    for name in "$@"; do
      if [[ $name == tree-memory || $name == artifact-sizes || $name == world-plan || $name == package-build ]]; then seed_check || failed=1; fi
      if [[ $name == artifact-sizes ]]; then
        resolve_packages
        for key in "${packages[@]}"; do
          dir=.out/artifacts/x86_64/v2/sha256/$key
          expected=$(jaq -er '.payload_sha256' "$dir/artifact.json") || { echo "preflight: missing package manifest $key"; failed=1; continue; }
          actual=$(sha256sum "$dir/payload.tar.gz") || { echo "preflight: missing package payload $key"; failed=1; continue; }
          if [[ ${actual%% *} != "$expected" ]]; then echo "preflight: stale package $key"; failed=1; fi
        done
      fi
    done
    if (( failed )); then echo 'preflight: nothing ran'; exit 1; fi
    ;;
  execute)
    run_dir=$1; name=$2; shift 2
    mkdir -p .work/bench
    setsid bash bench/support.sh workload "$name" "$run_dir" "$@" &
    pid=$!
    printf '%s\n' "$pid" > ".work/bench/$pid.pid"
    wait "$pid"; status=$?
    if ! ps -eo pgid=,stat= | awk -v pgid="$pid" '$1 == pgid && $2 !~ /^Z/ {found=1} END {exit !found}'; then rm -f ".work/bench/$pid.pid"; fi
    exit "$status"
    ;;
  workload)
    set -e
    name=$1; run_dir=$2; shift 2
    if [[ $name == tree-memory || $name == artifact-sizes ]]; then resolve_image; fi
    if [[ $name == tree-memory ]]; then
      seed_abs=$(realpath "$seed")
      mkdir -p "$run_dir/container"
      docker run --rm --network none --mount "type=bind,src=$root,dst=/src/laputa,readonly" --mount "type=bind,src=$seed_abs,dst=/seed,readonly" --mount "type=bind,src=$seed_abs,dst=/.out/seed/x86_64,readonly" --mount "type=bind,src=$root/$run_dir/container,dst=/output" --workdir /src/laputa --env XSH_PM_OFFLINE=1 --env XSH_MODULE_PATH=/src/laputa:/output/modules/core --label laputa.bench=tree-memory "$image" /bin/sh -c 'mkdir -p /output/modules && tar -xJf /seed/core.tar.xz -C /output/modules && /seed/xsh /src/laputa/pm.xsh -- repo plan --repo /src/laputa --root baselayout --target x86_64-linux-musl --output /output/plan.json && test -s /output/plan.json && /bin/cat /sys/fs/cgroup/memory.peak' > "$run_dir/memory.raw" || exit 1
      peak=$(tail -n 1 "$run_dir/memory.raw")
      bash bench/support.sh oracle "$peak" "$run_dir/container/plan.json" || exit 1
      printf 'metric\ttree-memory\t%s\n' "$peak"
      echo 'scope=container-cgroup oracle=nonempty-plan'
      sha256sum "$seed/xsh" "$seed/core.tar.xz" "$seed/manifest.json"
      docker image inspect --format 'image id={{.Id}} layers={{json .RootFS.Layers}}' "$image"
    elif [[ $name == artifact-sizes ]]; then
      for name in "${products[@]}"; do printf 'metric\tseed-%s\t%s\n' "$name" "$(stat -c %s "$seed/$name")"; sha256sum "$seed/$name"; done
      resolve_packages
      for key in "${packages[@]}"; do
        dir=.out/artifacts/x86_64/v2/sha256/$key
        id=$(jaq -r '.package_id' "$dir/artifact.json") || exit 1
        echo "package $id key=$key"
        expected=$(jaq -er '.payload_sha256' "$dir/artifact.json") || exit 1
        actual=$(sha256sum "$dir/payload.tar.gz") || exit 1
        [[ ${actual%% *} == "$expected" ]] || exit 1
        printf 'metric\tpackage-%s\t%s\n' "${id%%-[0-9]*}" "$(stat -c %s "$dir/payload.tar.gz")"; printf '%s\n' "$actual"
      done
      docker image inspect --format 'image id={{.Id}} layers={{json .RootFS.Layers}}' "$image" || exit 1
      printf 'metric\tpackage-tools-image\t%s\n' "$(docker image inspect --format '{{.Size}}' "$image")"
      echo 'excluded installer ISO: not built'
    else
      exec "$@"
    fi
    ;;
  report)
    set -e
    run_dir=$1
    echo "commit=$(git rev-parse HEAD)"
    echo "dirty=$(if [[ -n $(git status --porcelain) ]]; then echo true; else echo false; fi)"
    echo "xsh_head=$(git -C "$xsh_root" rev-parse HEAD)"
    sha256sum "${BENCH_XSH:?}" "${BENCH_XSHT:?}"
    echo "host=$(uname -a)"
    for log in "$run_dir"/*.log; do
      item=${log##*/}; item=${item%.log}
      echo "host readiness before $item:"; cat "$run_dir/$item.before.ready"
      echo "host readiness after $item:"; cat "$run_dir/$item.after.ready"
      read -r before after < "$run_dir/$item.ready-status"
      ready=0; if [[ $before != 0 || $after != 0 ]]; then ready=75; fi
      echo "host readiness exit before=$before after=$after"
      cat "$log"
      while IFS=$'\t' read -r marker key value; do
        [[ $marker == metric ]] || continue
        anchor=-; tolerance=0; anchor_commit=-; anchor_host=-; anchor_date=-
        while IFS=$'\t' read -r akey avalue atolerance acommit ahost adate; do
          if [[ $akey == "$key" && $avalue =~ ^[0-9]+$ && $atolerance =~ ^[0-9]+$ && -n $acommit && $ahost == "$(uname -n)" && -n $adate ]]; then anchor=$avalue; tolerance=$atolerance; anchor_commit=$acommit; anchor_host=$ahost; anchor_date=$adate; fi
        done < bench/anchors.tsv
        echo "verdict $key: $(verdict "$ready" "$value" "$anchor" "$tolerance") anchor=$anchor tolerance=$tolerance anchor_commit=$anchor_commit anchor_host=$anchor_host anchor_date=$anchor_date"
      done < "$log"
    done
    ;;
  *) exit 2 ;;
esac
