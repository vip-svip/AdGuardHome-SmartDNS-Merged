/^sni_filter:/ {
    print "sni_filter:"
    print "  enabled: true"
    print "  ports:"
    print "    - 80"
    print "    - 443"
    print "    - 8443"
    print "    - 2053"
    print "    - 2054"
    print "    - 2083"
    print "    - 2087"
    print "    - 2089"
    print "    - 2091"
    print "    - 2096"
    print "    - 2480"
    print "  queue_num: 7"
    print "  drop_quic: true"
    skip = 1
    next
}
skip && /^[^[:space:]]/ { skip = 0 }
skip { next }
{ print }
