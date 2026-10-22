#!/usr/bin/env bash
#MISE description="Write coverage.xml from JaCoCo execution data and the classes the tests ran against"
#USAGE arg "<jacoco-cli>" help="Directory holding the JaCoCo CLI jar (see the copyJacocoCli task)"
#USAGE arg "<classes>" help="Directory of the classes the tests ran against (see the collectDebugClasses task)"
#USAGE arg "<execution-data>" help="Directory searched for .ec and .exec files"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

jacoco_cli=$(find "$1" -name '*.jar' | head -1)
classes=$2

mapfile -t execution_data < <(find "$3" -name '*.ec' -o -name '*.exec')

if [ ${#execution_data[@]} -eq 0 ]; then
    echo "No execution data was recorded. What is under $3:"
    find "$3"
    exit 1
fi

java -jar "$jacoco_cli" report "${execution_data[@]}" \
    --classfiles "$classes" \
    --sourcefiles "${SCRIPT_DIR}/../app/src/main/java" \
    --xml coverage.xml 2>&1 | tee report.log

# A class whose bytecode JaCoCo cannot match has its execution data dropped and is reported as
# uncovered, so a mismatch understates the result instead of failing.
if grep -q 'does not match' report.log; then
    echo "The classes above were not the ones the tests ran against, so their coverage was dropped."
    exit 1
fi

# A report that resolved no classes still writes valid XML, so it is worth saying so here rather
# than uploading an empty one.
if ! grep -q '<counter' coverage.xml; then
    echo "The report counted nothing. The classes it was given:"
    find "$classes" -name '*.class' | head
    exit 1
fi
