#socat TCP-LISTEN:8006,fork TCP:192.168.0.188:3389 &
socat TCP-LISTEN:8007,fork TCP:192.168.0.221:3389 & # for win10 rdp
socat TCP-LISTEN:8008,fork TCP:192.168.0.188:22 & # to connect to devvm (tiny) 
socat TCP-LISTEN:8009,fork TCP:192.168.0.188:4000 & # to connect to nomachine devvm (tiny) 
socat TCP-LISTEN:8010,fork TCP:192.168.0.246:22 & # to connect to buildvm (big) 
