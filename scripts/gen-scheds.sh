#!/bin/bash

DIR=$(dirname $0)
ROOT=$DIR/..
OPT=$ROOT/build/Release+Asserts/bin/opt
SCAF=$ROOT/build/Release+Asserts/lib/Scaffold.so

D=(1024)
K=(2)

# Generate .ll file if not done already
for f in $*; do
  b=$(basename $f .scaffold)
  echo "[schedule.sh] $b: Compiling ..."
  if [ -n ${b}.ll ]; then
    # Generate compiled files
    $ROOT/scaffold.sh -r $f
    mv ${b}11.ll ${b}11.ll.keep_me
    # clean intermediary compilation files (comment out for speed)
    $ROOT/scaffold.sh -c $f
    # Keep the final output for the compilation
    mv ${b}11.ll.keep_me ${b}.ll
  fi
done

# Module inlining pass with a 2M-operation threshold
for f in $*; do
  b=$(basename $f .scaffold)
  echo "[schedule.sh] $b: Flattening ..."
  if [ -n ${b}_inline2M.ll ]; then
    $OPT -S -load $SCAF -ResourceCount2 ${b}.ll > /dev/null 2> ${b}.out
    python $DIR/flattening_thresh_2M.py ${b} > /dev/null
    for i in ${b}_inline2M.txt; do
      cp ${i} inline_info.txt
      $OPT -S -load $SCAF -InlineModule -dce -internalize -globaldce ${b}.ll -o ${b}_inline2M.ll
    done
  fi
  rm inline_info.txt ${b}.out
done

# Perform resource estimation 
for f in $*; do
  b=$(basename $f .scaffold)
  echo "[schedule.sh] $b: Resource count ..."
  if [ -n ${b}_inline2M.resources ]; then
    $OPT -S -load $SCAF -ResourceCount ${b}_inline2M.ll > /dev/null 2> ${b}_inline2M.resources
  fi
done

# For different K and D values specified above, generate MultiSIMD schedules (only for leaf modules which are flat)
for f in $*; do
  b=$(basename $f .scaffold)
  for d in ${D[@]}; do
    for k in ${K[@]}; do
      echo "[schedule.sh] $b: Generating SIMD K=$k D=$d leaves ..."
      if [ ! -e ${b}_inline2M.simd.${k}.${d}.leaves ]; then
        $OPT -load $SCAF -GenSIMDSchedule -simd-kconstraint $k -simd-dconstraint $d ${b}_inline2M.ll > /dev/null 2> ${b}_inline2M.simd.${k}.${d}
        ${DIR}/leaves.pl ${b}_inline2M.simd.${k}.${d} > ${b}_inline2M.simd.${k}.${d}.leaves
      fi
    done
  done
done

# Perform different kinds of LPFS, RCP, SS scheduling, as specified in the regress.sh file
for f in $*; do
  b=$(basename $f .scaffold)
  echo "[schedule.sh] $b: Generating LPFS, RCP, SS leaves ..."
  #${DIR}/full_sched_regress.sh ${b}*.leaves
  # Only generate metrics, not full schedule. Use this for speed.
  ${DIR}/regress.sh ${b}*.leaves  
done

# Take into account the penalty of ballistic communication
for f in $*; do
  b=$(basename $f .scaffold)
  echo "[schedule.sh] $b: Adding communication latencies ..."
  ${DIR}/comm_aware.pl ${b}*.ss ${b}*.lpfs ${b}*.rcp
done

# Obtain coarse-grain schedules by co-scheduling modules
for f in $*; do
  b=$(basename $f .scaffold)
  for c in comm_aware_schedule.txt.${b}_*; do
    k=$(perl -e '$ARGV[0] =~ /_K(\d)/; print $1' $c)
    d=$(perl -e '$ARGV[0] =~ /_D(\d+)/; print $1' $c)
    x=$(perl -e '$ARGV[0] =~ /.*_(.+)/; print $1' $c)
    echo "[schedule.sh] $b: Coarse-grain schedule ..."
    cp $c comm_aware_schedule.txt
    if [ ! -e ${b}_inline2M.simd.${k}.${d}.${x}.time ]; then
      $OPT -load $SCAF -GenCGSIMDSchedule -simd-kconstraint-cg $k -simd-dconstraint-cg $d ${b}_inline2M.ll > /dev/null 2> ${b}_inline2M.simd.${k}.${d}.${x}.time
    fi

    # Now do 0-communication cost
    if [ ! -e ${b}_inline2M.simd.${k}.${d}.w0.${x}.time ]; then
      $OPT -load $SCAF -GenCGSIMDSchedule -move-weight-cg 0 -simd-kconstraint-cg $k -simd-dconstraint-cg $d ${b}_inline2M.ll > /dev/null 2> ${b}_inline2M.simd.${k}.${d}.w0.${x}.time
    fi
  done
  rm comm_aware_schedule.txt
done

# Create directory to put all byproduct and output files in
for f in $*; do
  b=$(basename $f .scaffold)  
  echo "[schedule.sh] $b: Moving files to output directory ..."
  mkdir -p "$b"
  mv ./*${b}* ${b} 2>/dev/null
done


