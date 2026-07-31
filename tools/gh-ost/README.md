# gh-ost 바이너리

`ghcr.io/github/gh-ost` 는 접근이 거부되고 Docker Hub 에 공식 이미지가 없다.
소스에서 빌드해 쓴다. `go.mod` 가 Go 1.25.12 이상을 요구하므로 1.24 로는 빌드가 안 된다.

```console
$ git clone --depth 1 https://github.com/github/gh-ost.git
$ docker run --rm -v "$PWD/gh-ost":/src -w /src golang:1.25-alpine \
    sh -c "go build -o /src/gh-ost ./go/cmd/gh-ost"
```

`gh-ost.linux-arm64` 는 그렇게 만든 정적 링크 바이너리다(Apple Silicon 의 리눅스 컨테이너용).
다른 아키텍처가 필요하면 같은 명령을 그 플랫폼에서 돌린다.
