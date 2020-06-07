#!/usr/bin/env bash

#
# Regression tests
#
# Compare the results of different projects and spat runs with stored templates.
#

# Remove possibly leftover temp files
rm -f test.diff *.out

# First argument is the project directory
# Second argument the project file (.gpr) within that project.
run_check () {
  for SPAT_OPTIONS in "-s -l -d -ca" "-s -l -d -ct"; do
    ../obj/run_spat -s -l -d -ct -P "$1/$2" > "spat.$1.$SPAT_OPTIONS.out"
    # Show template differences (FIXME: 'diff' might not be installed)
    (diff -u "spat.$1.$SPAT_OPTIONS.template" "spat.$1.$SPAT_OPTIONS.out") >> test.diff || RESULT=$?
  done
}

# run the freshly built executable on the files and store the result in spat.out
# -s  for summary
# -l  for list
# -d  for details
# -ca sort alphabetically
# -ct sort by time

RESULT=0

run_check "test-saatana" "saatana.gpr"
run_check "test-sparknacl" "src/sparknacl.gpr"

case $RESULT in
[0-1])
  if [ -s test.diff ]; then
    echo "Test failed, there are differences."
    cat test.diff
    RESULT=1
  else
    echo "Test succeeded."
    RESULT=0
  fi
  ;;
*)
  echo "One or more diffs failed."
esac

# Remove temp files
rm -f test.diff *.out

exit $RESULT