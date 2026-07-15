# OSRM routing server (Railway)

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/REPLACE_WITH_TEMPLATE_SLUG)

> After you publish this as a Railway template (see "Publish as a Railway
> template" below), replace `REPLACE_WITH_TEMPLATE_SLUG` in the button URL above
> with your template's slug so one-click deploys work.

A self-hosted OSRM server. Defaults to the **whole US** (`us-latest`); set the
`PBF_URL` variable to any Geofabrik extract to cover a different region. The KWI
load planner calls its `/trip` endpoint to get real road miles and optimal stop
order (set the URL in Admin -> Settings -> `osrm_url`). Without it the app uses a
straight-line estimate x 1.26.

The same image builds the map once (download + osrm-extract/partition/customize
into the `/data` volume) and then serves it. First deploy is slow (30-90 min);
every restart after that serves in about a minute because the processed graph
persists on the volume.

## Deploy on Railway (dashboard + GitHub)

1. Put this `osrm-railway` folder in its own GitHub repo (e.g. `kwi-osrm`) and push.
2. Railway -> New Project -> Deploy from GitHub repo -> pick `kwi-osrm`.
3. Service -> Settings -> Build: confirm Builder is **Dockerfile**.
4. Service -> add a **Volume**, mount path **`/data`**, size ~**80 GB**.
5. Deploy. Open **Deploy Logs** and watch. You'll see the download, then
   `osrm-extract`, `osrm-partition`, `osrm-customize`, then
   `>> Serving OSRM (MLD) on 0.0.0.0:...`.
6. Service -> Settings -> **Networking** -> Generate Domain. Copy the `https://` URL.
7. Test it (any browser):
   `https://YOUR-DOMAIN/route/v1/driving/-95.36,29.76;-97.74,30.27?overview=false`
   Expect JSON with `"code":"Ok"`.
8. In KWI: Admin -> Settings -> `osrm_url` = the `https://` domain (no trailing
   slash). Save.
9. Rebuild loads. Trip sheets now show real road miles (`routed_by: osrm`).

## Deploy on Railway (CLI, no GitHub)

```
npm i -g @railway/cli
cd osrm-railway
railway login
railway init
railway up
```
Then add the Volume (`/data`) and a public Domain in the dashboard as above.

## Publish as a Railway template

Turn this repo into a one-click template on the Railway marketplace:

1. Deploy it once yourself (steps above) so you have a working service with the
   `/data` volume attached.
2. Project -> Settings -> **Publish as Template** (or railway.com/compose ->
   add a service from this GitHub repo).
3. In the template config, set:
   - **Source:** this GitHub repo (`judetelan/osrm-NA`), builder = Dockerfile.
   - **Volume:** mount path `/data`, size ~80 GB.
   - **Variables (optional, shown to the deployer):** `PBF_URL` (default the US
     extract), `OSRM_NAME` (default `us-latest`).
4. Publish. Railway gives you a template slug/URL (`railway.com/deploy/<slug>`)
   and a "Deploy on Railway" button snippet — paste the slug into the button at
   the top of this README.

Anyone (including future you) can then spin up the same US OSRM server in one
click; they still wait out the one-time build on first boot.

## Notes

- **Memory:** the build peaks around 15-18 GB for the US car profile; Pro's
  24 GB covers it. If a log line says `Killed` during extract, it ran out of
  memory — tell the dev and we'll switch to a lighter approach.
- **Cost:** an always-on ~8 GB service bills continuously. You can **Stop** the
  service between load builds and **Start** it a minute before building — the
  volume keeps the processed graph, so a restart just serves (no rebuild).
- **Security:** the URL is public and unauthenticated. It only answers routing
  queries (no KW data), so low risk, but don't post it publicly. Ask the dev if
  you want it locked behind a token.
- **Refresh the map later:** to rebuild with newer OSM data, delete the `READY`
  file (and old `us-latest.osrm.*`) on the volume, then redeploy.

Env vars (optional): `PBF_URL` (default US extract), `OSRM_NAME` (default
`us-latest`). `PORT` is provided by Railway.
