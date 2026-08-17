nslookup 8.8.8.8 | awk '
    /^Name:/ {seen=1}
    /^Address/ && seen {
        for (i=2; i<=NF; i++) {
            if (($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || $i ~ /:/) && $i !~ /^[0-9]+:$/) {
                print $i
            }
        }
    }
' | sort | tr '\n' ' ' | awk '{$1=$1; print $0}'
