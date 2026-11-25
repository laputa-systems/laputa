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
    time=$(python3 -c 'import os, sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$file")
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
file_size() {
  local size
  size=$(wc -c < "$1")
  printf '%s\n' "${size##* }"
}
verdict() {
  local ready=$1 value=$2 anchor=$3 tolerance=$4 spread=${5:-0}
  if [[ $ready != 0 ]]; then echo 'inconclusive: host busy'
  elif [[ $anchor == - ]]; then echo 'inconclusive: no anchor'
  elif (( value - anchor - spread > tolerance )); then echo regression
  elif (( value - anchor + spread <= tolerance )); then echo 'within budget'
  else echo 'inconclusive: spread'
  fi
}
uptime_ns() {
  local elapsed idle whole fraction
  read -r elapsed idle < /proc/uptime
  whole=${elapsed%.*}; fraction=${elapsed#*.}
  printf '%s\n' "$((10#$whole * 1000000000 + 10#$fraction * 10000000))"
}
plan_oracle() {
  local plan=$1 expected=$2 reference=${3:--} digest
  jaq -e --rawfile expected "$expected" '([.nodes[].name] | sort) == ($expected | split("\n") | map(select(. != "")) | sort) and (.nodes | length > 0)' "$plan" >/dev/null || return 1
  digest=$(sha256sum "$plan"); digest=${digest%% *}
  [[ $reference == - || $digest == "$reference" ]] || return 1
  printf '%s\n' "$digest"
}
build_oracle() {
  local plan=$1 log=$2 count
  count=$(jaq -er '.nodes | length | select(. > 0)' "$plan") || return 1
  ! rg -q '^repo build (start|done|FAILED) ' "$log" || return 1
  [[ $(rg -c "^repo build [0-9a-f]+ $count artifacts$" "$log") == 1 ]] || return 1
  printf 'reused=%s builds=0\n' "$count"
}
root_oracle() {
  local plan=$1 receipt=$2
  jaq -e --slurpfile plan "$plan" '([.artifacts[] | select(.payload) | .artifact_key] | sort) == ([$plan[0].nodes[].artifact_key] | sort) and ([.artifacts[].package_name] | sort) == ["baselayout", "xsh"] and (.entries | length > 0)' "$receipt" >/dev/null
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
  plan-oracle) plan_oracle "$@" ;;
  build-oracle) build_oracle "$@" ;;
  root-oracle) root_oracle "$@" ;;
  oracle) [[ $1 =~ ^[1-9][0-9]*$ ]] && jaq -e '[.nodes[] | select(.name == "baselayout")] | length > 0' "$2" >/dev/null ;;
  check)
    failed=0
    children_check || failed=1
    if command -v docker >/dev/null; then
      containers=$(docker ps --filter label=laputa.bench --format '{{.ID}} {{.Names}}') || { echo 'preflight: cannot inspect containers'; failed=1; containers=; }
      if [[ -n $containers ]]; then echo "preflight: surviving benchmark container $containers"; failed=1; fi
    fi
    for name in "$@"; do
      if [[ $name == tree-memory || $name == artifact-sizes || $name == world-plan || $name == package-build || $name == warm-rebuild || $name == root-compose || $name == mirror-publish ]]; then seed_check || failed=1; fi
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
    if [[ $name == tree-memory || $name == artifact-sizes || $name == world-plan || $name == warm-rebuild || $name == root-compose ]]; then resolve_image; fi
    if [[ $name == mirror-publish || $name == profile-ready || $name == xinit-service-start ]]; then
      journey=$(realpath "$run_dir")/$name-journey
      mkdir -p "$journey"
      if [[ $name == mirror-publish ]]; then
        resolve_image
        seed_abs=$(realpath "$seed")
        store_abs=$(realpath "${BENCH_STORE:-.out/artifacts/x86_64}")
        mkdir -p "$journey/repo/.out/seed/x86_64" "$journey/modules" "$journey/output"
        for path in "$root"/*; do ln -s "/source/${path##*/}" "$journey/repo/${path##*/}"; done
        tar -xJf "$seed/core.tar.xz" -C "$journey/modules"
        docker run --rm --user "$(id -u):$(id -g)" --network none --label laputa.bench=mirror-plan --mount "type=bind,src=$root,dst=/source,readonly" --mount "type=bind,src=$journey/repo,dst=/repo,readonly" --mount "type=bind,src=$seed_abs,dst=/repo/.out/seed/x86_64,readonly" --mount "type=bind,src=$seed_abs,dst=/seed,readonly" --mount "type=bind,src=$journey/modules,dst=/modules,readonly" --mount "type=bind,src=$journey/output,dst=/output" --workdir /repo --env XSH_PM_OFFLINE=1 --env XSH_MODULE_PATH=/repo:/modules/core "$image" /seed/xsh /repo/pm.xsh -- repo plan --repo /repo --root baselayout --target x86_64-linux-musl --output /output/closure.json
        printf 'baselayout\nxsh\n' > "$journey/expected"
        plan_oracle "$journey/output/closure.json" "$journey/expected" >/dev/null
        export BENCH_PLAN="$journey/output/closure.json" BENCH_STORE="$store_abs"
        export BENCH_MIRROR="${BENCH_MIRROR:-.out/host/x86_64/laputa-mirror}"
        BENCH_MIRROR=$(realpath "$BENCH_MIRROR")
        export XSH_MODULE_PATH="$root:$xsh_root/core"
        mode=publish
      elif [[ $name == profile-ready ]]; then
        export BENCH_PROFILE_IMAGE="${BENCH_PROFILE_IMAGE:-target/laputa/qemu-tinyland-ghostty/current}"
        BENCH_PROFILE_IMAGE=$(realpath "$BENCH_PROFILE_IMAGE")
        mode=boot
      else
        mode=service
      fi
      busy=0; samples=()
      for round in 1 2 3 4 5; do
        perf-gate-ready > "$journey/before-$round" 2>&1 || busy=1
        status=0
        sample=$(python3 bench/scenario.py "$mode" "$journey/round-$round") || status=$?
        perf-gate-ready -1 > "$journey/after-$round" 2>&1 || busy=1
        (( status == 0 )) || exit "$status"
        [[ $sample =~ ^[0-9]+$ ]] || exit 1
        samples+=("$sample")
        echo "round=$round duration_ns=$sample oracle=passed"
      done
      mapfile -t sorted < <(printf '%s\n' "${samples[@]}" | sort -n)
      spread=$((sorted[4]-sorted[0]))
      printf 'metric\t%s-ns\t%s\t%s\t%s\n' "$name" "${sorted[2]}" "$spread" "$busy"
    elif [[ $name == tree-memory ]]; then
      seed_abs=$(realpath "$seed")
      mkdir -p "$run_dir/container"
      docker run --rm --network none --mount "type=bind,src=$root,dst=/src/laputa,readonly" --mount "type=bind,src=$seed_abs,dst=/seed,readonly" --mount "type=bind,src=$seed_abs,dst=/.out/seed/x86_64,readonly" --mount "type=bind,src=$root/$run_dir/container,dst=/output" --workdir /src/laputa --env XSH_PM_OFFLINE=1 --env XSH_MODULE_PATH=/src/laputa:/output/modules/core --label laputa.bench=tree-memory "$image" /bin/sh -c 'mkdir -p /output/modules && tar -xJf /seed/core.tar.xz -C /output/modules && /seed/xsh /src/laputa/pm.xsh -- repo plan --repo /src/laputa --root baselayout --target x86_64-linux-musl --output /output/plan.json && test -s /output/plan.json && /bin/cat /sys/fs/cgroup/memory.peak' > "$run_dir/memory.raw" || exit 1
      peak=$(tail -n 1 "$run_dir/memory.raw")
      bash bench/support.sh oracle "$peak" "$run_dir/container/plan.json" || exit 1
      printf 'metric\ttree-memory\t%s\n' "$peak"
      echo 'scope=container-cgroup oracle=nonempty-plan'
      sha256sum "$seed/xsh" "$seed/core.tar.xz" "$seed/manifest.json"
      docker image inspect --format 'image id={{.Id}} layers={{json .RootFS.Layers}}' "$image"
    elif [[ $name == world-plan || $name == warm-rebuild || $name == root-compose ]]; then
      seed_abs=$(realpath "$seed")
      store=${BENCH_STORE:-.out/artifacts/x86_64}
      store_abs=$(realpath "$store")
      mkdir -p "$run_dir/$name-journey/repo/.out/seed/x86_64" "$run_dir/$name-journey/modules" "$run_dir/$name-journey/output"
      journey=$(realpath "$run_dir/$name-journey")
      for path in "$root"/*; do ln -s "/source/${path##*/}" "$journey/repo/${path##*/}"; done
      tar -xJf "$seed/core.tar.xz" -C "$journey/modules"
      docker_args=(run --rm --network none --label "laputa.bench=$name" --mount "type=bind,src=$root,dst=/source,readonly" --mount "type=bind,src=$journey/repo,dst=/repo,readonly" --mount "type=bind,src=$seed_abs,dst=/repo/.out/seed/x86_64,readonly" --mount "type=bind,src=$seed_abs,dst=/seed,readonly" --mount "type=bind,src=$store_abs,dst=/artifacts,readonly" --mount "type=bind,src=$journey/modules,dst=/modules,readonly" --mount "type=bind,src=$journey/output,dst=/output" --workdir /repo --env XSH_PM_OFFLINE=1 --env XSH_MODULE_PATH=/repo:/modules/core "$image" /seed/xsh /repo/pm.xsh --)
      printf 'baselayout\nxsh\n' > "$journey/expected"
      docker "${docker_args[@]}" repo plan --repo /repo --root baselayout --target x86_64-linux-musl --output /output/closure.json
        plan_oracle "$journey/output/closure.json" "$journey/expected" >/dev/null
        while read -r key; do
          dir="$store_abs/v2/sha256/$key"
          expected=$(jaq -er '.payload_sha256' "$dir/artifact.json")
          actual=$(sha256sum "$dir/payload.tar.gz"); [[ ${actual%% *} == "$expected" ]]
        done < <(jaq -r '.nodes[].artifact_key' "$journey/output/closure.json")
      if [[ $name == world-plan ]]; then
        for recipe in packages/*/PKGBUILD.xsh; do basename "${recipe%/PKGBUILD.xsh}"; done | sort > "$journey/expected"
      fi
      busy=0; reference=-; samples=()
      for round in 1 2 3 4 5; do
        perf-gate-ready > "$journey/before-$round" 2>&1 || busy=1
        start=$(uptime_ns)
        status=0
        case $name in
          world-plan) docker "${docker_args[@]}" repo plan --repo /repo --all --target x86_64-linux-musl --output "/output/plan-$round.json" > "$journey/round-$round.log" || status=$? ;;
          warm-rebuild) docker "${docker_args[@]}" repo build /output/closure.json --store /artifacts --jobs 1 > "$journey/round-$round.log" || status=$? ;;
          root-compose) docker "${docker_args[@]}" root compose /output/closure.json --store /artifacts --runtime-root baselayout --output "/output/root-$round" > "$journey/round-$round.log" || status=$? ;;
        esac
        end=$(uptime_ns)
        perf-gate-ready -1 > "$journey/after-$round" 2>&1 || busy=1
        (( status == 0 )) || exit "$status"
        samples+=("$((end-start))")
        case $name in
          world-plan) reference=$(plan_oracle "$journey/output/plan-$round.json" "$journey/expected" "$reference") ;;
          warm-rebuild) build_oracle "$journey/output/closure.json" "$journey/round-$round.log" ;;
          root-compose) root_oracle "$journey/output/closure.json" "$journey/output/root-$round/var/lib/laputa/root.json" ;;
        esac
        echo "round=$round duration_ns=${samples[-1]} oracle=passed"
      done
      mapfile -t sorted < <(printf '%s\n' "${samples[@]}" | sort -n)
      spread=$((sorted[4]-sorted[0]))
      printf 'metric\t%s-ns\t%s\t%s\t%s\n' "$name" "${sorted[2]}" "$spread" "$busy"
    elif [[ $name == artifact-sizes ]]; then
      for name in "${products[@]}"; do printf 'metric\tseed-%s\t%s\n' "$name" "$(file_size "$seed/$name")"; sha256sum "$seed/$name"; done
      resolve_packages
      for key in "${packages[@]}"; do
        dir=.out/artifacts/x86_64/v2/sha256/$key
        id=$(jaq -r '.package_id' "$dir/artifact.json") || exit 1
        echo "package $id key=$key"
        expected=$(jaq -er '.payload_sha256' "$dir/artifact.json") || exit 1
        actual=$(sha256sum "$dir/payload.tar.gz") || exit 1
        [[ ${actual%% *} == "$expected" ]] || exit 1
        printf 'metric\tpackage-%s\t%s\n' "${id%%-[0-9]*}" "$(file_size "$dir/payload.tar.gz")"; printf '%s\n' "$actual"
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
      while IFS=$'\t' read -r marker key value spread round_busy; do
        [[ $marker == metric ]] || continue
        spread=${spread:-0}; round_busy=${round_busy:-0}
        metric_ready=$ready; if [[ $round_busy != 0 ]]; then metric_ready=75; fi
        anchor=-; tolerance=0; anchor_commit=-; anchor_host=-; anchor_date=-
        while IFS=$'\t' read -r akey avalue atolerance acommit ahost adate; do
          if [[ $akey == "$key" && $avalue =~ ^[0-9]+$ && $atolerance =~ ^[0-9]+$ && -n $acommit && $ahost == "$(uname -n)" && -n $adate ]]; then anchor=$avalue; tolerance=$atolerance; anchor_commit=$acommit; anchor_host=$ahost; anchor_date=$adate; fi
        done < bench/anchors.tsv
        echo "verdict $key: $(verdict "$metric_ready" "$value" "$anchor" "$tolerance" "$spread") value=$value spread=$spread anchor=$anchor tolerance=$tolerance anchor_commit=$anchor_commit anchor_host=$anchor_host anchor_date=$anchor_date"
      done < "$log"
    done
    ;;
  *) exit 2 ;;
esac
