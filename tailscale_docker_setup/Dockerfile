# Use the official Tailscale image as a base
FROM nginx 

# Install socat
RUN apt-get update && \
    apt-get install -y socat net-tools iputils-ping openssh-client  && \
    apt-get install -y tmux procps netcat-traditional && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY ./run_socat.sh /root/run_socat.sh
RUN chmod +x /root/run_socat.sh
CMD ["nginx", "-g", "daemon off;"]
#CMD ["bash", "/root/run_socat.sh &"]
ENTRYPOINT ["/root/run_socat.sh"]
