FROM ghcr.io/efabless/openlane2:3.0.1

# Fetch pinned SKY130 PDK
RUN ciel fetch sky130

WORKDIR /design
COPY src/rv32i_cpu.v src/
COPY src/rv32i_cpu.sdc src/
COPY config.json .

# Run full PnR flow
CMD ["python3", "-m", "openlane", "config.json"]
