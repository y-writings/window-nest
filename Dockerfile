FROM swift:6.0.3-jammy@sha256:a159706c0c52c1025998a87bc2ab3ceba71416a00110b31cc2ab08d9184341c9

WORKDIR /workspace

COPY Package.swift ./
COPY Sources ./Sources
COPY Tests ./Tests

CMD ["swift", "test"]
