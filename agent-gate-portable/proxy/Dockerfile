# =============================================================================
# Stage 1 — Builder: compile Go proxy with CGO disabled for static binary
# =============================================================================
FROM golang:1.22-alpine AS builder

WORKDIR /build

# Cache module downloads in separate layer
COPY go.mod go.sum ./
RUN go mod download

# Build the binary
COPY . .
RUN CGO_ENABLED=0 go build -o /proxy .

# =============================================================================
# Stage 2 — Runtime: minimal Alpine image
# =============================================================================
FROM alpine:latest

RUN apk add --no-cache ca-certificates

COPY --from=builder /proxy /usr/local/bin/proxy

EXPOSE 8080

CMD ["proxy"]
