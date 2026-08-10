# Kubernetes deployment

Plain manifests — no Helm, no operator. Two objects: a Secret holding the five
required variables, and a single-replica Deployment.

There is no Service or Ingress. Nothing in this container listens on a port;
it only makes outbound connections to the camera and to YouTube.

## Deploy

1. Create the Secret from your existing `.env` (easiest, and keeps the
   credentials out of git):

   ```bash
   kubectl create secret generic eufycam-youtube-restream --from-env-file=../../.env
   ```

   Or copy `secret.example.yaml` to `secret.yaml`, fill it in, and
   `kubectl apply -f secret.yaml`. `secret.yaml` is gitignored.

2. Set the image tag in `deployment.yaml` to the version you want, then:

   ```bash
   kubectl apply -f deployment.yaml
   ```

3. Watch it come up:

   ```bash
   kubectl rollout status deploy/eufycam-youtube-restream
   kubectl logs -f deploy/eufycam-youtube-restream
   ```

   You should see `starting ffmpeg (audio: ...)`. Credentials are redacted
   from anything ffmpeg logs.

## If the image is private

The GHCR package is private until you make it public. While it is private,
nodes need a pull secret:

```bash
kubectl create secret docker-registry ghcr \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<a PAT with read:packages>
```

then add to the pod spec:

```yaml
      imagePullSecrets:
        - name: ghcr
```

Making the package public under the repo's **Packages → Package settings** is
simpler if you don't mind the image being world-readable — the container holds
no secrets, they all arrive via env vars.

## Rotating the stream key

```bash
kubectl create secret generic eufycam-youtube-restream \
  --from-env-file=../../.env --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deploy/eufycam-youtube-restream
```

The restart is required — env vars from a Secret are injected at pod start and
do not update in place.

## Notes

- **`replicas: 1` is not arbitrary.** Two pods would push two ffmpeg sessions
  to the same stream key and YouTube will reject or flap between them. The
  `Recreate` strategy exists for the same reason.
- **There is intentionally no `livenessProbe`.** `entrypoint.sh` already
  restarts ffmpeg internally; a probe that restarts the pod would duplicate
  that supervisor and cause churn on every transient drop. (Kubernetes ignores
  the image's Docker `HEALTHCHECK` entirely.)
- **Camera reachability.** The pod needs a network route to the camera's LAN
  address. On a cluster with a separate pod network, confirm egress to that
  subnet is permitted before debugging anything else.
