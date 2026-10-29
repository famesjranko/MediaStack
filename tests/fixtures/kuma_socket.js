// Runs inside the tested Kuma image, using its own Socket.IO client. Credentials
// arrive on stdin and no authentication tokens or push tokens leave this process.
const fs = require("fs");
const { io } = require("socket.io-client");
const credentials = JSON.parse(fs.readFileSync(0, "utf8"));
const mode = process.argv[1];
const name = "MediaStack migration fixture";
const slug = "migration-fixture";
const socket = io("http://127.0.0.1:3001", {
    transports: ["websocket"], reconnection: false, timeout: 10000,
});
const deadline = setTimeout(() => {
    console.error("Kuma fixture deadline exceeded");
    process.exit(1);
}, 60000);

function event(name) {
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`Kuma event timed out: ${name}`)), 10000);
        socket.once(name, (value) => { clearTimeout(timer); resolve(value); });
    });
}

function call(name, ...args) {
    return new Promise((resolve, reject) => {
        socket.timeout(10000).emit(name, ...args, (error, result) => {
            if (error || !result || result.ok !== true) {
                // Server errors can contain user data. Report only the event.
                reject(new Error(`Kuma request failed: ${name}`));
            } else {
                resolve(result);
            }
        });
    });
}

async function monitors() {
    const list = event("monitorList");
    await call("getMonitorList");
    return Object.values(await list);
}

async function push(token, status, ping) {
    const query = new URLSearchParams({status, ping: String(ping), msg: `migration-${status}`});
    const response = await fetch(`http://127.0.0.1:3001/api/push/${token}?${query}`, {
        signal: AbortSignal.timeout(10000),
    });
    if (!response.ok || (await response.json()).ok !== true) {
        throw new Error("Kuma fixture push failed");
    }
}

async function seed() {
    for (const monitor of await monitors()) {
        if (monitor.name === name) await call("deleteMonitor", monitor.id);
    }
    const { monitorID } = await call("add", {
        type: "push", name, interval: 3600, retryInterval: 60,
        maxretries: 0, maxredirects: 0, notificationIDList: {}, conditions: [],
        accepted_statuscodes: ["200-299"],
        pushToken: require("crypto").randomBytes(16).toString("hex"),
    });
    const { monitor } = await call("getMonitor", monitorID);
    // Different statuses create real incident history and nonzero uptime data.
    await push(monitor.pushToken, "up", 12);
    await new Promise((resolve) => setTimeout(resolve, 1200));
    await push(monitor.pushToken, "down", 30);
    await new Promise((resolve) => setTimeout(resolve, 1200));
    await push(monitor.pushToken, "up", 24);
    await call("pauseMonitor", monitorID);
    await call("setSettings", {keepDataPeriodDays: 365}, credentials.password);
    const config = {
        slug, title: name, theme: "dark", published: true, showTags: false,
        showPoweredBy: false, showCertificateExpiry: false,
        showOnlyLastHeartbeat: false, analyticsType: null, domainNameList: [],
    };
    const pages = await fetch("http://127.0.0.1:3001/api/status-page/" + slug, {
        signal: AbortSignal.timeout(10000),
    });
    if (pages.status === 404) await call("addStatusPage", name, slug);
    else if (!pages.ok) throw new Error("Kuma fixture status page read failed");
    await call("saveStatusPage", slug, config, "", [{
        name: "Migration history", monitorList: [{id: monitorID}],
    }]);
}

async function snapshot() {
    const list = await monitors();
    const fixture = list.find((monitor) => monitor.name === name);
    if (!fixture) throw new Error("Kuma lost the fixture monitor");
    const charts = {};
    for (const [label, hours] of [["minute", 24], ["hour", 720], ["day", 8760]]) {
        charts[label] = (await call("getMonitorChartData", fixture.id, hours)).data;
    }
    const pages = {};
    for (const page of ["mediastack", slug]) {
        const response = await fetch("http://127.0.0.1:3001/api/status-page/" + page, {
            signal: AbortSignal.timeout(10000),
        });
        if (!response.ok) throw new Error("Kuma status page read failed");
        pages[page] = await response.json();
    }
    // Select public monitor fields before crossing the process boundary.
    const fields = ["id", "name", "type", "url", "active", "interval", "retryInterval",
        "maxretries", "method", "accepted_statuscodes", "maxredirects"];
    const publicMonitors = list.map((m) => {
        const row = Object.fromEntries(fields.map((field) => [field, m[field]]));
        if (m.type === "push") {
            if (typeof m.pushToken !== "string" || !m.pushToken) {
                throw new Error("Kuma push token is missing");
            }
            row.pushTokenFingerprint = require("crypto").createHash("sha256").update(m.pushToken).digest("hex");
        }
        return row;
    });
    return {
        monitors: publicMonitors,
        settings: (await call("getSettings")).data,
        history: (await call("getMonitorBeats", fixture.id, 720)).data,
        charts, pages,
    };
}

(async () => {
    try {
        await event("connect");
        await call("login", credentials);
        if (mode === "seed") await seed();
        else if (mode === "drop") {
            const fixture = (await monitors()).find((monitor) => monitor.name === name);
            if (!fixture) throw new Error("Kuma lost the fixture monitor");
            await call("clearHeartbeats", fixture.id);
        } else if (mode !== "snapshot") throw new Error("Unknown Kuma fixture action");
        console.log(JSON.stringify(await snapshot()));
    } catch (error) {
        console.error(error.message);
        process.exitCode = 1;
    } finally {
        clearTimeout(deadline);
        socket.disconnect();
    }
})();
