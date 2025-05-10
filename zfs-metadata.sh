#!/bin/bash

# This script was primarily created to benchmark ZFS performance on a system with two HDDs and one NVMe SSD.
# It was mostly created by all the AIs (ChatGPT, Clade, and Gemini) but was tested and modified by me.

set -euo pipefail

ulimit -n 65535

# uncomment for debugging
# set -x


# This assumes 3 drives.  Update as needed with your drive Ids.
HDD1="/dev/disk/by-id/ata-ST14000NM001G-2KJ103_ZL2BGXCP" 
HDD2="/dev/disk/by-id/ata-ST14000NM001G-2KJ103_ZTM0EPJ3"
NVME_SPECIAL="/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S73VNJ0W900704V"

TEST_COUNT=100000
RESULT_DIR="/mnt/test-results/$(date +%F-%H%M%S)"
FIO_RUNTIME=120
FIO_JOBS=4
RANDOM_SEED=12345

mkdir -p "$RESULT_DIR"

ORIGINAL_ARC_MAX=$(cat /sys/module/zfs/parameters/zfs_arc_max)
echo "Original ARC max: $ORIGINAL_ARC_MAX bytes"
echo 67108864 > /sys/module/zfs/parameters/zfs_arc_max

echo "Recording original zfs module parameters..."
mkdir -p "$RESULT_DIR/zfs_params"
for param in $(find /sys/module/zfs/parameters -type f); do
  if [ -r "$param" ]; then
    cp "$param" "$RESULT_DIR/zfs_params/" 2>/dev/null || echo "Could not copy $param"
  fi
done

uname -a > "$RESULT_DIR/system_info.txt"
lsblk -o NAME,SIZE,VENDOR,MODEL,SERIAL >> "$RESULT_DIR/system_info.txt"
cat /proc/cpuinfo > "$RESULT_DIR/cpu_info.txt"
cat /proc/meminfo > "$RESULT_DIR/mem_info.txt"

should_rebuild_pool() {
  local DIR=$1
  [ ! -d "$DIR" ] && return 0
  local COUNT
  COUNT=$(find "$DIR" -type f -size 4k 2>/dev/null | wc -l || echo 0)
  [ "$COUNT" -ne "$TEST_COUNT" ]
}

if should_rebuild_pool /mnt/test-1/testdata; then
  echo "Rebuilding test-1..."
  zpool destroy -f test-1 || true
  rm -rf /mnt/test-1
  zpool create -f -o ashift=12 -m /mnt/test-1 test-1 "$HDD1"
  zfs create -o recordsize=4K -o primarycache=none -o secondarycache=none -o sync=always test-1/testdata
  zfs set mountpoint=/mnt/test-1/testdata test-1/testdata
else
  echo "test-1 test files present, skipping pool rebuild"
  zfs set primarycache=none test-1/testdata
  zfs set secondarycache=none test-1/testdata
  zfs set sync=always test-1/testdata
fi

if should_rebuild_pool /mnt/test-2/testdata; then
  echo "Rebuilding test-2..."
  zpool destroy -f test-2 || true
  rm -rf /mnt/test-2
  zpool create -f -o ashift=12 -m /mnt/test-2 test-2 "$HDD2" special "$NVME_SPECIAL"
  zfs create -o recordsize=4K -o special_small_blocks=1M -o primarycache=none -o secondarycache=none -o sync=always test-2/testdata
  zfs set mountpoint=/mnt/test-2/testdata test-2/testdata
  zfs set special_small_blocks=1M test-2/testdata
else
  echo "test-2 test files present, skipping pool rebuild"
  zfs set primarycache=none test-2/testdata
  zfs set secondarycache=none test-2/testdata
  zfs set sync=always test-2/testdata
fi

echo "ZFS Configuration for test-1/testdata:" > "$RESULT_DIR/zfs_config.txt"
zfs get -H -o property,value all test-1/testdata >> "$RESULT_DIR/zfs_config.txt"
echo "" >> "$RESULT_DIR/zfs_config.txt"
echo "ZFS Configuration for test-2/testdata:" >> "$RESULT_DIR/zfs_config.txt"
zfs get -H -o property,value all test-2/testdata >> "$RESULT_DIR/zfs_config.txt"
echo "Pool Status:" >> "$RESULT_DIR/zfs_config.txt"
zpool status test-1 >> "$RESULT_DIR/zfs_config.txt"
zpool status test-2 >> "$RESULT_DIR/zfs_config.txt"

prepare_test_data() {
  local DIR=$1
  local NAME=$2
  local DATASET=$3
  local COUNT
  COUNT=$(find "$DIR" -type f -size 4k 2>/dev/null | wc -l || echo 0)
  echo "$NAME: $COUNT test files present"

  if [ "$COUNT" -ne "$TEST_COUNT" ]; then
    echo "Removing existing files in $DIR"
    find "$DIR" -type f -delete

    echo "Generating $TEST_COUNT files for $NAME using fast method..."
    local ORIGINAL_PRIMARY=$(zfs get -H -o value primarycache "$DATASET")
    local ORIGINAL_SECONDARY=$(zfs get -H -o value secondarycache "$DATASET")
    local ORIGINAL_SYNC=$(zfs get -H -o value sync "$DATASET")
    zfs set primarycache=all "$DATASET"
    zfs set secondarycache=all "$DATASET"
    zfs set sync=disabled "$DATASET"

    local MAX_OPEN_FILES=$(ulimit -n)
    local FILES_PER_JOB=$((MAX_OPEN_FILES / 10))
    local BATCH_SIZE=1000
    if [ "$FILES_PER_JOB" -lt "$BATCH_SIZE" ]; then
        BATCH_SIZE=$FILES_PER_JOB
    fi

    echo "Creating files in batches of $BATCH_SIZE"
    local REMAINING=$TEST_COUNT
    local START=0

    while [ "$REMAINING" -gt 0 ]; do
        local CURRENT_BATCH=$BATCH_SIZE
        if [ "$REMAINING" -lt "$BATCH_SIZE" ]; then
            CURRENT_BATCH=$REMAINING
        fi

        echo "Creating batch: $CURRENT_BATCH files (starting at $START)"

        local FILES=()
        for ((i = 0; i < CURRENT_BATCH; i++)); do
            FILES+=(--filename="${DIR}/${NAME}.$((START + i))")
        done

        if ! fio --name="prepare-$NAME-batch-$START" \
          "${FILES[@]}" \
          --bs=4k --rw=write --ioengine=libaio --iodepth=16 \
          --filesize=4k --size=$((CURRENT_BATCH * 4096)) \
          --direct=1 --numjobs=4 --group_reporting --fallocate=none \
          >> "$RESULT_DIR/prepare-${NAME}.txt" 2>&1; then
            echo "FIO failed during file creation batch starting at $START"
            tail -20 "$RESULT_DIR/prepare-${NAME}.txt"
            exit 1
        fi

        START=$((START + CURRENT_BATCH))
        REMAINING=$((REMAINING - CURRENT_BATCH))
        echo "Completed batch. Remaining: $REMAINING files"
    done

    sync
    sleep 3
    zfs set primarycache=$ORIGINAL_PRIMARY "$DATASET"
    zfs set secondarycache=$ORIGINAL_SECONDARY "$DATASET"
    zfs set sync=$ORIGINAL_SYNC "$DATASET"

    ACTUAL_COUNT=$(find "$DIR" -type f -size 4k | wc -l)
    echo "$NAME: $ACTUAL_COUNT files created"
    if [ "$ACTUAL_COUNT" -ne "$TEST_COUNT" ]; then
      echo "WARNING: Expected $TEST_COUNT files but found $ACTUAL_COUNT files"
    fi
  else
    echo "$NAME test files are already in place"
  fi
}



echo "Preparing test data..."
prepare_test_data "/mnt/test-1/testdata" "test1" "test-1/testdata"
prepare_test_data "/mnt/test-2/testdata" "test2" "test-2/testdata"

flush_caches() {
  echo "Flushing caches thoroughly..."
  sync
  echo 3 > /proc/sys/vm/drop_caches

  zfs_arc_size=$(cat /proc/spl/kstat/zfs/arcstats | grep -w size | awk '{print $3}')
  echo "Current ARC size: $zfs_arc_size"
  echo 0 > /sys/module/zfs/parameters/zfs_arc_max
  sleep 2
  echo 67108864 > /sys/module/zfs/parameters/zfs_arc_max
  sleep 10
  zfs_arc_size=$(cat /proc/spl/kstat/zfs/arcstats | grep -w size | awk '{print $3}')
  echo "ARC size after flush: $zfs_arc_size"

  free -m > "$RESULT_DIR/memory_status.txt"
}

record_pool_stats() {
  local PHASE=$1
  echo "===== $PHASE =====" >> "$RESULT_DIR/pool_stats.txt"
  zpool iostat -v test-1 test-2 >> "$RESULT_DIR/pool_stats.txt"
  echo "" >> "$RESULT_DIR/pool_stats.txt"
}

run_fio_test() {
  local NAME=$1
  local DIR=$2
  local MODE=$3
  local IODEPTH=$4

  echo "Running $NAME..."
  record_pool_stats "Before-${NAME}"
  flush_caches
  echo "Starting FIO test $NAME with mode=$MODE, iodepth=$IODEPTH"

  # Create a temporary job file for FIO to avoid command line length limits
  local FIO_JOB_FILE="$RESULT_DIR/${NAME}-job.fio"
  
  echo "[global]" > "$FIO_JOB_FILE"
  echo "bs=4k" >> "$FIO_JOB_FILE"
  echo "rw=$MODE" >> "$FIO_JOB_FILE"
  echo "ioengine=libaio" >> "$FIO_JOB_FILE"
  echo "iodepth=$IODEPTH" >> "$FIO_JOB_FILE"
  echo "filesize=4k" >> "$FIO_JOB_FILE"
  echo "direct=1" >> "$FIO_JOB_FILE"
  echo "numjobs=$FIO_JOBS" >> "$FIO_JOB_FILE"
  echo "runtime=$FIO_RUNTIME" >> "$FIO_JOB_FILE"
  echo "time_based=1" >> "$FIO_JOB_FILE"
  echo "randseed=$RANDOM_SEED" >> "$FIO_JOB_FILE"
  echo "group_reporting=1" >> "$FIO_JOB_FILE"
  echo "invalidate=1" >> "$FIO_JOB_FILE"
  echo "fallocate=none" >> "$FIO_JOB_FILE"
  echo "rate_iops=0" >> "$FIO_JOB_FILE"
  echo "rate_process=poisson" >> "$FIO_JOB_FILE"
  
  echo "[$NAME]" >> "$FIO_JOB_FILE"
  echo "directory=$DIR" >> "$FIO_JOB_FILE"
  echo "filename_format=${NAME%%-*}.\$jobnum.\$filenum" >> "$FIO_JOB_FILE"
  echo "nrfiles=$((TEST_COUNT / FIO_JOBS))" >> "$FIO_JOB_FILE"
  
  echo "FIO job file created at $FIO_JOB_FILE"
  
  if ! fio "$FIO_JOB_FILE" --output="$RESULT_DIR/${NAME}.txt"; then
      echo "FIO test $NAME failed"
      tail -20 "$RESULT_DIR/${NAME}.txt"
      exit 1
  fi

  echo "Test completed. Summary:"
  grep -A 8 "Run status group" "$RESULT_DIR/${NAME}.txt" | head -9
  echo ""

  record_pool_stats "After-${NAME}"
  echo "$NAME complete."
  echo ""
}



#!/bin/bash
set -euo pipefail

ulimit -n 65535

# uncomment for debugging
# set -x


HDD1="/dev/disk/by-id/ata-ST14000NM001G-2KJ103_ZL2BGXCP"
HDD2="/dev/disk/by-id/ata-ST14000NM001G-2KJ103_ZTM0EPJ3"
NVME_SPECIAL="/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_S73VNJ0W900704V"

TEST_COUNT=100000
RESULT_DIR="/mnt/test-results/$(date +%F-%H%M%S)"
FIO_RUNTIME=120
FIO_JOBS=4
RANDOM_SEED=12345

mkdir -p "$RESULT_DIR"

ORIGINAL_ARC_MAX=$(cat /sys/module/zfs/parameters/zfs_arc_max)
echo "Original ARC max: $ORIGINAL_ARC_MAX bytes"
echo 67108864 > /sys/module/zfs/parameters/zfs_arc_max

echo "Recording original zfs module parameters..."
mkdir -p "$RESULT_DIR/zfs_params"
for param in $(find /sys/module/zfs/parameters -type f); do
  if [ -r "$param" ]; then
    cp "$param" "$RESULT_DIR/zfs_params/" 2>/dev/null || echo "Could not copy $param"
  fi
done

uname -a > "$RESULT_DIR/system_info.txt"
lsblk -o NAME,SIZE,VENDOR,MODEL,SERIAL >> "$RESULT_DIR/system_info.txt"
cat /proc/cpuinfo > "$RESULT_DIR/cpu_info.txt"
cat /proc/meminfo > "$RESULT_DIR/mem_info.txt"

should_rebuild_pool() {
  local DIR=$1
  [ ! -d "$DIR" ] && return 0
  local COUNT
  COUNT=$(find "$DIR" -type f -size 4k 2>/dev/null | wc -l || echo 0)
  [ "$COUNT" -ne "$TEST_COUNT" ]
}

if should_rebuild_pool /mnt/test-1/testdata; then
  echo "Rebuilding test-1..."
  zpool destroy -f test-1 || true
  rm -rf /mnt/test-1
  zpool create -f -o ashift=12 -m /mnt/test-1 test-1 "$HDD1"
  zfs create -o recordsize=4K -o primarycache=none -o secondarycache=none -o sync=always test-1/testdata
  zfs set mountpoint=/mnt/test-1/testdata test-1/testdata
else
  echo "test-1 test files present, skipping pool rebuild"
  zfs set primarycache=none test-1/testdata
  zfs set secondarycache=none test-1/testdata
  zfs set sync=always test-1/testdata
fi

if should_rebuild_pool /mnt/test-2/testdata; then
  echo "Rebuilding test-2..."
  zpool destroy -f test-2 || true
  rm -rf /mnt/test-2
  zpool create -f -o ashift=12 -m /mnt/test-2 test-2 "$HDD2" special "$NVME_SPECIAL"
  zfs create -o recordsize=4K -o special_small_blocks=1M -o primarycache=none -o secondarycache=none -o sync=always test-2/testdata
  zfs set mountpoint=/mnt/test-2/testdata test-2/testdata
  zfs set special_small_blocks=1M test-2/testdata
else
  echo "test-2 test files present, skipping pool rebuild"
  zfs set primarycache=none test-2/testdata
  zfs set secondarycache=none test-2/testdata
  zfs set sync=always test-2/testdata
fi

echo "ZFS Configuration for test-1/testdata:" > "$RESULT_DIR/zfs_config.txt"
zfs get -H -o property,value all test-1/testdata >> "$RESULT_DIR/zfs_config.txt"
echo "" >> "$RESULT_DIR/zfs_config.txt"
echo "ZFS Configuration for test-2/testdata:" >> "$RESULT_DIR/zfs_config.txt"
zfs get -H -o property,value all test-2/testdata >> "$RESULT_DIR/zfs_config.txt"
echo "Pool Status:" >> "$RESULT_DIR/zfs_config.txt"
zpool status test-1 >> "$RESULT_DIR/zfs_config.txt"
zpool status test-2 >> "$RESULT_DIR/zfs_config.txt"

prepare_test_data() {
  local DIR=$1
  local NAME=$2
  local DATASET=$3
  local COUNT
  COUNT=$(find "$DIR" -type f -size 4k 2>/dev/null | wc -l || echo 0)
  echo "$NAME: $COUNT test files present"

  if [ "$COUNT" -ne "$TEST_COUNT" ]; then
    echo "Removing existing files in $DIR"
    find "$DIR" -type f -delete

    echo "Generating $TEST_COUNT files for $NAME using fast method..."
    local ORIGINAL_PRIMARY=$(zfs get -H -o value primarycache "$DATASET")
    local ORIGINAL_SECONDARY=$(zfs get -H -o value secondarycache "$DATASET")
    local ORIGINAL_SYNC=$(zfs get -H -o value sync "$DATASET")
    zfs set primarycache=all "$DATASET"
    zfs set secondarycache=all "$DATASET"
    zfs set sync=disabled "$DATASET"

    local MAX_OPEN_FILES=$(ulimit -n)
    local FILES_PER_JOB=$((MAX_OPEN_FILES / 10))
    local BATCH_SIZE=1000
    if [ "$FILES_PER_JOB" -lt "$BATCH_SIZE" ]; then
        BATCH_SIZE=$FILES_PER_JOB
    fi

    echo "Creating files in batches of $BATCH_SIZE"
    local REMAINING=$TEST_COUNT
    local START=0

    while [ "$REMAINING" -gt 0 ]; do
        local CURRENT_BATCH=$BATCH_SIZE
        if [ "$REMAINING" -lt "$BATCH_SIZE" ]; then
            CURRENT_BATCH=$REMAINING
        fi

        echo "Creating batch: $CURRENT_BATCH files (starting at $START)"

        local FILES=()
        for ((i = 0; i < CURRENT_BATCH; i++)); do
            FILES+=(--filename="${DIR}/${NAME}.$((START + i))")
        done

        if ! fio --name="prepare-$NAME-batch-$START" \
          "${FILES[@]}" \
          --bs=4k --rw=write --ioengine=libaio --iodepth=16 \
          --filesize=4k --size=$((CURRENT_BATCH * 4096)) \
          --direct=1 --numjobs=4 --group_reporting --fallocate=none \
          >> "$RESULT_DIR/prepare-${NAME}.txt" 2>&1; then
            echo "FIO failed during file creation batch starting at $START"
            tail -20 "$RESULT_DIR/prepare-${NAME}.txt"
            exit 1
        fi

        START=$((START + CURRENT_BATCH))
        REMAINING=$((REMAINING - CURRENT_BATCH))
        echo "Completed batch. Remaining: $REMAINING files"
    done

    sync
    sleep 3
    zfs set primarycache=$ORIGINAL_PRIMARY "$DATASET"
    zfs set secondarycache=$ORIGINAL_SECONDARY "$DATASET"
    zfs set sync=$ORIGINAL_SYNC "$DATASET"

    ACTUAL_COUNT=$(find "$DIR" -type f -size 4k | wc -l)
    echo "$NAME: $ACTUAL_COUNT files created"
    if [ "$ACTUAL_COUNT" -ne "$TEST_COUNT" ]; then
      echo "WARNING: Expected $TEST_COUNT files but found $ACTUAL_COUNT files"
    fi
  else
    echo "$NAME test files are already in place"
  fi
}



echo "Preparing test data..."
prepare_test_data "/mnt/test-1/testdata" "test1" "test-1/testdata"
prepare_test_data "/mnt/test-2/testdata" "test2" "test-2/testdata"

flush_caches() {
  echo "Flushing caches thoroughly..."
  sync
  echo 3 > /proc/sys/vm/drop_caches

  zfs_arc_size=$(cat /proc/spl/kstat/zfs/arcstats | grep -w size | awk '{print $3}')
  echo "Current ARC size: $zfs_arc_size"
  echo 0 > /sys/module/zfs/parameters/zfs_arc_max
  sleep 2
  echo 67108864 > /sys/module/zfs/parameters/zfs_arc_max
  sleep 10
  zfs_arc_size=$(cat /proc/spl/kstat/zfs/arcstats | grep -w size | awk '{print $3}')
  echo "ARC size after flush: $zfs_arc_size"

  free -m > "$RESULT_DIR/memory_status.txt"
}

record_pool_stats() {
  local PHASE=$1
  echo "===== $PHASE =====" >> "$RESULT_DIR/pool_stats.txt"
  zpool iostat -v test-1 test-2 >> "$RESULT_DIR/pool_stats.txt"
  echo "" >> "$RESULT_DIR/pool_stats.txt"
}

run_fio_test() {
  local NAME=$1
  local DIR=$2
  local MODE=$3
  local IODEPTH=$4

  echo "Running $NAME..."
  record_pool_stats "Before-${NAME}"
  flush_caches
  echo "Starting FIO test $NAME with mode=$MODE, iodepth=$IODEPTH"

  # Create a temporary job file for FIO to avoid command line length limits
  local FIO_JOB_FILE="$RESULT_DIR/${NAME}-job.fio"
  
  echo "[global]" > "$FIO_JOB_FILE"
  echo "bs=4k" >> "$FIO_JOB_FILE"
  echo "rw=$MODE" >> "$FIO_JOB_FILE"
  echo "ioengine=libaio" >> "$FIO_JOB_FILE"
  echo "iodepth=$IODEPTH" >> "$FIO_JOB_FILE"
  echo "filesize=4k" >> "$FIO_JOB_FILE"
  echo "direct=1" >> "$FIO_JOB_FILE"
  echo "numjobs=$FIO_JOBS" >> "$FIO_JOB_FILE"
  echo "runtime=$FIO_RUNTIME" >> "$FIO_JOB_FILE"
  echo "time_based=1" >> "$FIO_JOB_FILE"
  echo "randseed=$RANDOM_SEED" >> "$FIO_JOB_FILE"
  echo "group_reporting=1" >> "$FIO_JOB_FILE"
  echo "invalidate=1" >> "$FIO_JOB_FILE"
  echo "fallocate=none" >> "$FIO_JOB_FILE"
  echo "rate_iops=0" >> "$FIO_JOB_FILE"
  echo "rate_process=poisson" >> "$FIO_JOB_FILE"
  
  echo "[$NAME]" >> "$FIO_JOB_FILE"
  echo "directory=$DIR" >> "$FIO_JOB_FILE"
  echo "filename_format=${NAME%%-*}.\$jobnum.\$filenum" >> "$FIO_JOB_FILE"
  echo "nrfiles=$((TEST_COUNT / FIO_JOBS))" >> "$FIO_JOB_FILE"
  
  echo "FIO job file created at $FIO_JOB_FILE"
  
  if ! fio "$FIO_JOB_FILE" --output="$RESULT_DIR/${NAME}.txt"; then
      echo "FIO test $NAME failed"
      tail -20 "$RESULT_DIR/${NAME}.txt"
      exit 1
  fi

  echo "Test completed. Summary:"
  grep -A 8 "Run status group" "$RESULT_DIR/${NAME}.txt" | head -9
  echo ""

  record_pool_stats "After-${NAME}"
  echo "$NAME complete."
  echo ""
}



# Run tests
record_pool_stats "Initial"

# HDD pool
run_fio_test "benchmark-write-test1-iodepth1" "/mnt/test-1/testdata" "randwrite" 1
run_fio_test "benchmark-read-test1-iodepth1" "/mnt/test-1/testdata" "randread" 1
run_fio_test "benchmark-write-test1-iodepth16" "/mnt/test-1/testdata" "randwrite" 16
run_fio_test "benchmark-read-test1-iodepth16" "/mnt/test-1/testdata" "randread" 16

# HDD + special vdev
run_fio_test "benchmark-write-test2-iodepth1" "/mnt/test-2/testdata" "randwrite" 1
run_fio_test "benchmark-read-test2-iodepth1" "/mnt/test-2/testdata" "randread" 1
run_fio_test "benchmark-write-test2-iodepth16" "/mnt/test-2/testdata" "randwrite" 16
run_fio_test "benchmark-read-test2-iodepth16" "/mnt/test-2/testdata" "randread" 16

# Mixed workload
run_fio_test "benchmark-rw-test1" "/mnt/test-1/testdata" "randrw" 16
run_fio_test "benchmark-rw-test2" "/mnt/test-2/testdata" "randrw" 16

run_metadata_test() {
  local DIR=$1
  local NAME=$2

  echo "Running metadata tests on $NAME..."
  flush_caches

  # Sequential stat on all files
  local START=$(date +%s.%N)
  find "$DIR" -type f -exec stat '{}' + > /dev/null
  local END=$(date +%s.%N)
  local DURATION=$(awk "BEGIN {print $END - $START}")
  if [[ -z "$DURATION" ]]; then
    echo "  WARNING: Failed to calculate sequential stat duration"
    echo "$NAME sequential metadata test failed (duration missing)" > "$RESULT_DIR/metadata-${NAME}-sequential.txt"
  else
    echo "  $NAME sequential metadata test duration: ${DURATION}s"
    # Fix: Ensure proper file name format
    echo "$NAME sequential metadata test duration: ${DURATION}s" > "$RESULT_DIR/metadata-${NAME}-sequential.txt"
  fi

  flush_caches

  # Random stat on 20% of files - array-based approach
  echo "  Running random metadata test..."
  
  # Get list of files first
  readarray -t ALL_FILES < <(find "$DIR" -type f | head -n $TEST_COUNT)
  local FILE_COUNT=${#ALL_FILES[@]}
  
  # Calculate 20% of TEST_COUNT (or actual file count if lower)
  local SAMPLE_COUNT=$((TEST_COUNT * 20 / 100))
  if [ "$FILE_COUNT" -lt "$SAMPLE_COUNT" ]; then
    SAMPLE_COUNT=$FILE_COUNT
  fi
  
  echo "  Running random stat on $SAMPLE_COUNT files (20% of $TEST_COUNT) out of $FILE_COUNT..."
  
  # Create random indices
  local INDICES=()
  for ((i=0; i<FILE_COUNT; i++)); do
    INDICES+=($i)
  done
  
  # Shuffle the indices
  for ((i=FILE_COUNT-1; i>0; i--)); do
    j=$((RANDOM % (i+1)))
    # Swap indices[i] and indices[j]
    temp=${INDICES[i]}
    INDICES[i]=${INDICES[j]}
    INDICES[j]=$temp
  done
  
  # Stat the randomly selected files
  START=$(date +%s.%N)
  for ((i=0; i<SAMPLE_COUNT; i++)); do
    idx=${INDICES[i]}
    stat "${ALL_FILES[idx]}" > /dev/null
  done
  END=$(date +%s.%N)
  
  DURATION=$(awk "BEGIN {print $END - $START}")
  if [[ -z "$DURATION" ]]; then
    echo "  WARNING: Failed to calculate random stat duration"
    echo "$NAME random metadata test failed (duration missing)" > "$RESULT_DIR/metadata-${NAME}-random.txt"
  else
    echo "  $NAME random metadata test (${SAMPLE_COUNT} files) duration: ${DURATION}s"
    # Fix: Ensure proper file name format for random test results
    echo "$NAME random metadata test (${SAMPLE_COUNT} files) duration: ${DURATION}s" > "$RESULT_DIR/metadata-${NAME}-random.txt"
  fi
  
  # Debug check to verify files were created
  echo "  Metadata files created:"
  ls -la "$RESULT_DIR"/metadata-${NAME}-*.txt
}



# Run metadata tests
run_metadata_test "/mnt/test-1/testdata" "test-1"
run_metadata_test "/mnt/test-2/testdata" "test-2"

# Restore ARC max
echo "Restoring original ARC max value: $ORIGINAL_ARC_MAX"
echo "$ORIGINAL_ARC_MAX" > /sys/module/zfs/parameters/zfs_arc_max

# Create summary file
# Create summary file
echo "Creating result summary..."
{
  echo "ZFS Performance Test Results Summary"
  echo "===================================="
  echo "Date: $(date)"
  echo ""
  echo "Test Parameters:"
  echo "- Test file count: $TEST_COUNT"
  echo "- FIO runtime: $FIO_RUNTIME seconds"
  echo "- FIO jobs: $FIO_JOBS"
  echo ""
  echo "Systems under test:"
  echo "1. Standard ZFS on HDD: $HDD1"
  echo "2. ZFS with special VDEV: $HDD2 (main) + $NVME_SPECIAL (special)"
  echo ""

  for test in benchmark-*-test1-* benchmark-*-test2-*; do
    if [ -f "$RESULT_DIR/$test.txt" ]; then
      echo "==== $test ===="
      grep -A 1 "Run status group" "$RESULT_DIR/$test.txt" || echo "No results found"
      echo ""
    fi
  done

  echo "==== Metadata Tests ===="
  # Fix: Look for files directly rather than using grep -r
  echo "Sequential metadata tests:"
  for file in "$RESULT_DIR"/metadata-test-*-sequential.txt; do
    if [ -f "$file" ]; then
      cat "$file"
    fi
  done
  
  echo ""
  echo "Random metadata tests:"
  for file in "$RESULT_DIR"/metadata-test-*-random.txt; do
    if [ -f "$file" ]; then
      cat "$file"
    fi
  done
  echo ""
} > "$RESULT_DIR/summary.txt"



# Generate comparison
{
  echo "Performance Comparison: Regular ZFS vs. Special VDEV"
  echo "==================================================="
  echo ""
  echo "Read Performance:"
  echo "----------------"

  READ1_IOPS=$(grep -A 20 "benchmark-read-test1-iodepth16" "$RESULT_DIR/benchmark-read-test1-iodepth16.txt" 2>/dev/null | grep "IOPS=" | head -1 | sed -E 's/.*IOPS=([0-9.k]+).*/\1/g' || echo "N/A")
  READ2_IOPS=$(grep -A 20 "benchmark-read-test2-iodepth16" "$RESULT_DIR/benchmark-read-test2-iodepth16.txt" 2>/dev/null | grep "IOPS=" | head -1 | sed -E 's/.*IOPS=([0-9.k]+).*/\1/g' || echo "N/A")

  echo "HDD Only: $READ1_IOPS IOPS"
  echo "With Special VDEV: $READ2_IOPS IOPS"
  echo ""
  echo "Write Performance:"
  echo "-----------------"

  WRITE1_IOPS=$(grep -A 20 "benchmark-write-test1-iodepth16" "$RESULT_DIR/benchmark-write-test1-iodepth16.txt" 2>/dev/null | grep "IOPS=" | head -1 | sed -E 's/.*IOPS=([0-9.k]+).*/\1/g' || echo "N/A")
  WRITE2_IOPS=$(grep -A 20 "benchmark-write-test2-iodepth16" "$RESULT_DIR/benchmark-write-test2-iodepth16.txt" 2>/dev/null | grep "IOPS=" | head -1 | sed -E 's/.*IOPS=([0-9.k]+).*/\1/g' || echo "N/A")

  echo "HDD Only: $WRITE1_IOPS IOPS"
  echo "With Special VDEV: $WRITE2_IOPS IOPS"
  echo ""
  echo "Metadata Performance:"
  echo "--------------------"

  # Extract the duration values directly using cat and awk
  if [ -f "$RESULT_DIR/metadata-test-1-sequential.txt" ]; then
    META1_SEQ=$(cat "$RESULT_DIR/metadata-test-1-sequential.txt" | awk '{print $NF}' | sed 's/s//g')
  else 
    META1_SEQ="N/A"
  fi
  
  if [ -f "$RESULT_DIR/metadata-test-2-sequential.txt" ]; then
    META2_SEQ=$(cat "$RESULT_DIR/metadata-test-2-sequential.txt" | awk '{print $NF}' | sed 's/s//g')
  else
    META2_SEQ="N/A"
  fi
  
  if [ -f "$RESULT_DIR/metadata-test-1-random.txt" ]; then
    META1_RAND=$(cat "$RESULT_DIR/metadata-test-1-random.txt" | awk '{print $NF}' | sed 's/s//g')
  else
    META1_RAND="N/A"
  fi
  
  if [ -f "$RESULT_DIR/metadata-test-2-random.txt" ]; then
    META2_RAND=$(cat "$RESULT_DIR/metadata-test-2-random.txt" | awk '{print $NF}' | sed 's/s//g')
  else
    META2_RAND="N/A"
  fi

  echo "Sequential Metadata (lower is better):"
  echo "  HDD Only: ${META1_SEQ}s"
  echo "  With Special VDEV: ${META2_SEQ}s"
  echo ""
  echo "Random Metadata (lower is better):"
  echo "  HDD Only: ${META1_RAND}s"
  echo "  With Special VDEV: ${META2_RAND}s"
} > "$RESULT_DIR/comparison.txt"

# Debug - verify files and content
echo "Final files in results directory:"
find "$RESULT_DIR" -type f -name "*.txt" | sort
echo ""
echo "Metadata file contents:"
for file in "$RESULT_DIR"/metadata-*.txt; do
  if [ -f "$file" ]; then
    echo "--- $file ---"
    cat "$file"
    echo ""
  fi
done



# Print final message
cat "$RESULT_DIR/summary.txt"
echo ""
echo "All tests completed. Results in $RESULT_DIR"

run_metadata_test() {
  local DIR=$1
  local NAME=$2

  echo "Running metadata tests on $NAME..."
  flush_caches

  # Sequential stat on all files
  local START=$(date +%s.%N)
  find "$DIR" -type f -exec stat '{}' + > /dev/null
  local END=$(date +%s.%N)
  local DURATION=$(awk "BEGIN {print $END - $START}")
  if [[ -z "$DURATION" ]]; then
    echo "  WARNING: Failed to calculate sequential stat duration"
    echo "$NAME sequential metadata test failed (duration missing)" > "$RESULT_DIR/metadata-${NAME}-sequential.txt"
  else
    echo "  $NAME sequential metadata test duration: ${DURATION}s"
    # Fix: Ensure proper file name format
    echo "$NAME sequential metadata test duration: ${DURATION}s" > "$RESULT_DIR/metadata-${NAME}-sequential.txt"
  fi

  flush_caches

  # Random stat on 20% of files - array-based approach
  echo "  Running random metadata test..."
  
  # Get list of files first
  readarray -t ALL_FILES < <(find "$DIR" -type f | head -n $TEST_COUNT)
  local FILE_COUNT=${#ALL_FILES[@]}
  
  # Calculate 20% of TEST_COUNT (or actual file count if lower)
  local SAMPLE_COUNT=$((TEST_COUNT * 20 / 100))
  if [ "$FILE_COUNT" -lt "$SAMPLE_COUNT" ]; then
    SAMPLE_COUNT=$FILE_COUNT
  fi
  
  echo "  Running random stat on $SAMPLE_COUNT files (20% of $TEST_COUNT) out of $FILE_COUNT..."
  
  # Create random indices
  local INDICES=()
  for ((i=0; i<FILE_COUNT; i++)); do
    INDICES+=($i)
  done
  
  # Shuffle the indices
  for ((i=FILE_COUNT-1; i>0; i--)); do
    j=$((RANDOM % (i+1)))
    # Swap indices[i] and indices[j]
    temp=${INDICES[i]}
    INDICES[i]=${INDICES[j]}
    INDICES[j]=$temp
  done
  
  # Stat the randomly selected files
  START=$(date +%s.%N)
  for ((i=0; i<SAMPLE_COUNT; i++)); do
    idx=${INDICES[i]}
    stat "${ALL_FILES[idx]}" > /dev/null
  done
  END=$(date +%s.%N)
  
  DURATION=$(awk "BEGIN {print $END - $START}")
  if [[ -z "$DURATION" ]]; then
    echo "  WARNING: Failed to calculate random stat duration"
    echo "$NAME random metadata test failed (duration missing)" > "$RESULT_DIR/metadata-${NAME}-random.txt"
  else
    echo "  $NAME random metadata test (${SAMPLE_COUNT} files) duration: ${DURATION}s"
    # Fix: Ensure proper file name format for random test results
    echo "$NAME random metadata test (${SAMPLE_COUNT} files) duration: ${DURATION}s" > "$RESULT_DIR/metadata-${NAME}-random.txt"
  fi
  
  # Debug check to verify files were created
  echo "  Metadata files created:"
  ls -la "$RESULT_DIR"/metadata-${NAME}-*.txt
}



# Run metadata tests
run_metadata_test "/mnt/test-1/testdata" "test-1"
run_metadata_test "/mnt/test-2/testdata" "test-2"

# Restore ARC max
echo "Restoring original ARC max value: $ORIGINAL_ARC_MAX"
echo "$ORIGINAL_ARC_MAX" > /sys/module/zfs/parameters/zfs_arc_max

# Create summary file
# Create summary file
echo "Creating result summary..."
{
  echo "ZFS Performance Test Results Summary"
  echo "===================================="
  echo "Date: $(date)"
  echo ""
  echo "Test Parameters:"
  echo "- Test file count: $TEST_COUNT"
  echo "- FIO runtime: $FIO_RUNTIME seconds"
  echo "- FIO jobs: $FIO_JOBS"
  echo ""
  echo "Systems under test:"
  echo "1. Standard ZFS on HDD: $HDD1"
  echo "2. ZFS with special VDEV: $HDD2 (main) + $NVME_SPECIAL (special)"
  echo ""

  for test in benchmark-*-test1-* benchmark-*-test2-*; do
    if [ -f "$RESULT_DIR/$test.txt" ]; then
      echo "==== $test ===="
      grep -A 1 "Run status group" "$RESULT_DIR/$test.txt" || echo "No results found"
      echo ""
    fi
  done

  echo "==== Metadata Tests ===="
  # Fix: Look for files directly rather than using grep -r
  echo "Sequential metadata tests:"
  for file in "$RESULT_DIR"/metadata-test-*-sequential.txt; do
    if [ -f "$file" ]; then
      cat "$file"
    fi
  done
  
  echo ""
  echo "Random metadata tests:"
  for file in "$RESULT_DIR"/metadata-test-*-random.txt; do
    if [ -f "$file" ]; then
      cat "$file"
    fi
  done
  echo ""
} > "$RESULT_DIR/summary.txt"



# Generate comparison
{
  echo "Performance Comparison: Regular ZFS vs. Special VDEV"
  echo "==================================================="
  echo ""
  echo "Read Performance:"
  echo "----------------"

  READ1_IOPS=$(grep -A 20 "benchmark-read-test1-iodepth16" "$RESULT_DIR/benchmark-read-test1-iodepth16.txt" 2>/dev/null | grep "IOPS=" | head -1 | sed -E 's/.*IOPS=([0-9.k]+).*/\1/g' || echo "N/A")
  READ2_IOPS=$(grep -A 20 "benchmark-read-test2-iodepth16" "$RESULT_DIR/benchmark-read-test2-iodepth16.txt" 2>/dev/null | grep "IOPS=" | head -1 | sed -E 's/.*IOPS=([0-9.k]+).*/\1/g' || echo "N/A")

  echo "HDD Only: $READ1_IOPS IOPS"
  echo "With Special VDEV: $READ2_IOPS IOPS"
  echo ""
  echo "Write Performance:"
  echo "-----------------"

  WRITE1_IOPS=$(grep -A 20 "benchmark-write-test1-iodepth16" "$RESULT_DIR/benchmark-write-test1-iodepth16.txt" 2>/dev/null | grep "IOPS=" | head -1 | sed -E 's/.*IOPS=([0-9.k]+).*/\1/g' || echo "N/A")
  WRITE2_IOPS=$(grep -A 20 "benchmark-write-test2-iodepth16" "$RESULT_DIR/benchmark-write-test2-iodepth16.txt" 2>/dev/null | grep "IOPS=" | head -1 | sed -E 's/.*IOPS=([0-9.k]+).*/\1/g' || echo "N/A")

  echo "HDD Only: $WRITE1_IOPS IOPS"
  echo "With Special VDEV: $WRITE2_IOPS IOPS"
  echo ""
  echo "Metadata Performance:"
  echo "--------------------"

  # Extract the duration values directly using cat and awk
  if [ -f "$RESULT_DIR/metadata-test-1-sequential.txt" ]; then
    META1_SEQ=$(cat "$RESULT_DIR/metadata-test-1-sequential.txt" | awk '{print $NF}' | sed 's/s//g')
  else 
    META1_SEQ="N/A"
  fi
  
  if [ -f "$RESULT_DIR/metadata-test-2-sequential.txt" ]; then
    META2_SEQ=$(cat "$RESULT_DIR/metadata-test-2-sequential.txt" | awk '{print $NF}' | sed 's/s//g')
  else
    META2_SEQ="N/A"
  fi
  
  if [ -f "$RESULT_DIR/metadata-test-1-random.txt" ]; then
    META1_RAND=$(cat "$RESULT_DIR/metadata-test-1-random.txt" | awk '{print $NF}' | sed 's/s//g')
  else
    META1_RAND="N/A"
  fi
  
  if [ -f "$RESULT_DIR/metadata-test-2-random.txt" ]; then
    META2_RAND=$(cat "$RESULT_DIR/metadata-test-2-random.txt" | awk '{print $NF}' | sed 's/s//g')
  else
    META2_RAND="N/A"
  fi

  echo "Sequential Metadata (lower is better):"
  echo "  HDD Only: ${META1_SEQ}s"
  echo "  With Special VDEV: ${META2_SEQ}s"
  echo ""
  echo "Random Metadata (lower is better):"
  echo "  HDD Only: ${META1_RAND}s"
  echo "  With Special VDEV: ${META2_RAND}s"
} > "$RESULT_DIR/comparison.txt"

# Debug - verify files and content
echo "Final files in results directory:"
find "$RESULT_DIR" -type f -name "*.txt" | sort
echo ""
echo "Metadata file contents:"
for file in "$RESULT_DIR"/metadata-*.txt; do
  if [ -f "$file" ]; then
    echo "--- $file ---"
    cat "$file"
    echo ""
  fi
done



# Print final message
cat "$RESULT_DIR/summary.txt"
echo ""
echo "All tests completed. Results in $RESULT_DIR"