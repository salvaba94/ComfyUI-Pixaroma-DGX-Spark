import { app } from "../../scripts/app.js";
import { api } from "../../scripts/api.js";

function hexToRgb(h) {
    h = (h || "#ffffff").replace("#", "");
    if (h.length !== 6) return [255, 255, 255];
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
}

function findUpstreamImageURL(node) {
    // Walk back to a LoadImage and grab its filename widget.
    const visited = new Set();
    const stack = [node];
    while (stack.length) {
        const n = stack.pop();
        if (!n || visited.has(n.id)) continue;
        visited.add(n.id);
        if (n.type === "LoadImage" && n.widgets) {
            const w = n.widgets.find(w => w.name === "image");
            if (w && w.value) {
                const name = typeof w.value === "string" ? w.value : w.value.name;
                const sub = name.includes("/") ? name.split("/") : [name];
                const filename = sub[sub.length - 1];
                const subfolder = sub.slice(0, -1).join("/");
                return `/view?filename=${encodeURIComponent(filename)}&subfolder=${encodeURIComponent(subfolder)}&type=input`;
            }
        }
        if (n.inputs) {
            for (const inp of n.inputs) {
                if (inp.link == null) continue;
                const link = app.graph.links[inp.link];
                if (!link) continue;
                const src = app.graph.getNodeById(link.origin_id);
                if (src) stack.push(src);
            }
        }
    }
    return null;
}

function drawFramed(ctx, img, params) {
    const { frame_style, frame_width, inner_padding, corner_radius, bevel, tint } = params;
    const fw = Math.max(0, frame_width | 0);
    const pad = Math.max(0, inner_padding | 0);
    const total = fw + pad;
    const W = img.width + 2 * total;
    const H = img.height + 2 * total;

    const canvas = ctx.canvas;
    canvas.width = W;
    canvas.height = H;
    ctx.clearRect(0, 0, W, H);

    // image
    ctx.drawImage(img, total, total);

    // matte
    if (pad > 0) {
        ctx.fillStyle = "rgb(20,20,20)";
        ctx.fillRect(fw, fw, W - 2 * fw, pad);
        ctx.fillRect(fw, H - fw - pad, W - 2 * fw, pad);
        ctx.fillRect(fw, fw, pad, H - 2 * fw);
        ctx.fillRect(W - fw - pad, fw, pad, H - 2 * fw);
    }

    // frame band — pixel buffer (mirrors Python compositor)
    if (fw > 0 && frame_style !== "none") {
        const palettes = {
            gold:   { dark:[90,55,10],   mid:[200,150,30],  hi:[255,233,150] },
            silver: { dark:[70,72,78],   mid:[170,173,180], hi:[245,247,250] },
            wood:   { dark:[45,22,8],    mid:[120,65,25],   hi:[190,125,65]  },
        };
        const pal = palettes[frame_style] || { dark:[60,60,60], mid:[140,140,140], hi:[220,220,220] };
        const tintRGB = hexToRgb(tint);
        const img2 = ctx.getImageData(0, 0, W, H);
        const data = img2.data;
        const denom = Math.max(fw - 1, 1);
        for (let y = 0; y < H; y++) {
            for (let x = 0; x < W; x++) {
                const top = y, left = x, bot = H - 1 - y, right = W - 1 - x;
                const d = Math.min(top, left, bot, right);
                if (d >= fw) continue;
                const t = d / denom;
                const rim = Math.max(0, Math.min(1, Math.min(t, 1 - t) * 2));
                let profile =
                    0.55 * (1 - Math.cos(Math.PI * t)) * 0.5 +
                    0.65 * Math.exp(-((t - 0.25) ** 2) / 0.015) +
                    0.25 * Math.exp(-((t - 0.7) ** 2) / 0.04);
                profile = Math.max(0, Math.min(1.5, profile * Math.pow(rim, 0.4)));
                const p  = Math.max(0, Math.min(1, profile));
                const p2 = Math.max(0, Math.min(1, profile - 1));
                let r = pal.dark[0] * (1 - p) + pal.mid[0] * p + (pal.hi[0] - pal.mid[0]) * p2;
                let g = pal.dark[1] * (1 - p) + pal.mid[1] * p + (pal.hi[1] - pal.mid[1]) * p2;
                let b = pal.dark[2] * (1 - p) + pal.mid[2] * p + (pal.hi[2] - pal.mid[2]) * p2;

                if (frame_style === "wood") {
                    const sideArr = [top, left, bot, right];
                    let side = 0;
                    for (let k = 1; k < 4; k++) if (sideArr[k] < sideArr[side]) side = k;
                    const along = (side === 0 || side === 2) ? x : y;
                    const across = d;
                    let grain =
                        0.55
                        + 0.22 * Math.sin(along * 0.06 + Math.sin(across * 0.4) * 1.5)
                        + 0.18 * Math.sin(along * 0.013 + 1.7)
                        + 0.10 * Math.sin(along * 0.31 + across * 0.2);
                    grain = Math.max(0.35, Math.min(1.15, grain));
                    r *= grain; g *= grain; b *= grain;
                } else {
                    const micro = 1 + 0.04 * Math.sin(y * 1.7 + x * 0.13) + 0.03 * Math.sin(x * 2.3);
                    r *= micro; g *= micro; b *= micro;
                }

                if (bevel > 0) {
                    const m = d;
                    const sign = (m === top || m === left) ? 1 : -1;
                    const adj = sign * (1 - t) * bevel * 55;
                    r += adj; g += adj; b += adj;
                }

                const rimDark = Math.exp(-(d * d) / 2) + Math.exp(-((fw - 1 - d) ** 2) / 2);
                r -= rimDark * 50; g -= rimDark * 50; b -= rimDark * 50;

                r = (r * tintRGB[0]) / 255;
                g = (g * tintRGB[1]) / 255;
                b = (b * tintRGB[2]) / 255;
                const i = (y * W + x) * 4;
                data[i]   = Math.max(0, Math.min(255, r));
                data[i+1] = Math.max(0, Math.min(255, g));
                data[i+2] = Math.max(0, Math.min(255, b));
                data[i+3] = 255;
            }
        }
        ctx.putImageData(img2, 0, 0);
    }

    // rounded corners — clip via destination-out
    if (corner_radius > 0) {
        const r = Math.min(corner_radius, Math.min(W, H) / 2);
        ctx.globalCompositeOperation = "destination-in";
        ctx.fillStyle = "#fff";
        ctx.beginPath();
        ctx.moveTo(r, 0);
        ctx.arcTo(W, 0, W, H, r);
        ctx.arcTo(W, H, 0, H, r);
        ctx.arcTo(0, H, 0, 0, r);
        ctx.arcTo(0, 0, W, 0, r);
        ctx.closePath();
        ctx.fill();
        ctx.globalCompositeOperation = "source-over";
    }
}

function openEditor(node) {
    const get = (name) => node.widgets.find(w => w.name === name);
    const params = {
        frame_style:   get("frame_style").value,
        frame_width:   get("frame_width").value,
        inner_padding: get("inner_padding").value,
        corner_radius: get("corner_radius").value,
        bevel:         get("bevel").value,
        tint:          get("tint").value,
    };

    if (!document.getElementById("pcf-style-tag")) {
        const st = document.createElement("style");
        st.id = "pcf-style-tag";
        st.textContent = `
        :root { --pcf-orange:#E85A2C; --pcf-orange-2:#ff7a44; }
        dialog.pcf-dlg { padding:0; border:1px solid #3a3a3a; background:#2b2b2b; color:#e6e6e6;
            border-radius:10px; max-width:92vw; max-height:92vh; box-shadow:0 12px 40px rgba(0,0,0,.6); font-family:'Segoe UI',sans-serif; }
        dialog.pcf-dlg::backdrop { background:rgba(0,0,0,.55); }
        .pcf-header { display:flex; align-items:center; gap:10px; padding:12px 16px; background:#222; border-bottom:1px solid #3a3a3a; border-radius:10px 10px 0 0; }
        .pcf-header h3 { margin:0; font-size:15px; font-weight:600; letter-spacing:.3px; color:#f0f0f0; }
        .pcf-header .pcf-dot { width:10px; height:10px; border-radius:50%; background:var(--pcf-orange); box-shadow:0 0 8px var(--pcf-orange); }
        .pcf-body { display:flex; gap:14px; padding:14px; }
        .pcf-preview { flex:1; min-width:420px; display:flex; align-items:center; justify-content:center; background:#1a1a1a;
            border:1px solid #3a3a3a; border-radius:8px; overflow:auto; max-height:80vh; }
        .pcf-preview canvas { max-width:100%; max-height:78vh; image-rendering:auto; }
        .pcf-controls { display:flex; flex-direction:column; gap:12px; width:250px; font-size:12px; }
        .pcf-controls label { display:flex; flex-direction:column; gap:5px; color:#bbb; font-weight:500; }
        .pcf-controls label .pcf-val { color:var(--pcf-orange); font-weight:600; margin-left:6px; }
        .pcf-controls select, .pcf-controls input[type=color] {
            background:#1f1f1f; color:#e6e6e6; border:1px solid #444; border-radius:5px; padding:6px 8px; font-size:12px; outline:none; }
        .pcf-controls select:focus { border-color:var(--pcf-orange); }
        .pcf-controls input[type=color] { padding:2px; height:30px; cursor:pointer; }
        .pcf-controls input[type=range] { -webkit-appearance:none; appearance:none; width:100%; height:5px;
            background:#1f1f1f; border-radius:3px; outline:none; border:1px solid #3a3a3a; }
        .pcf-controls input[type=range]::-webkit-slider-thumb { -webkit-appearance:none; appearance:none;
            width:16px; height:16px; border-radius:50%; background:var(--pcf-orange); border:2px solid #2b2b2b;
            box-shadow:0 0 4px rgba(232,90,44,.6); cursor:pointer; transition:transform .1s; }
        .pcf-controls input[type=range]::-webkit-slider-thumb:hover { transform:scale(1.15); background:var(--pcf-orange-2); }
        .pcf-controls input[type=range]::-moz-range-thumb { width:16px; height:16px; border-radius:50%;
            background:var(--pcf-orange); border:2px solid #2b2b2b; cursor:pointer; }
        .pcf-buttons { display:flex; gap:8px; margin-top:auto; }
        .pcf-buttons button { flex:1; padding:9px 12px; border-radius:6px; border:1px solid #444; background:#1f1f1f;
            color:#ddd; font-size:12px; font-weight:600; cursor:pointer; transition:all .15s; }
        .pcf-buttons button:hover { border-color:#666; background:#2a2a2a; }
        .pcf-buttons .pcf-save { background:var(--pcf-orange); border-color:var(--pcf-orange); color:#fff; }
        .pcf-buttons .pcf-save:hover { background:var(--pcf-orange-2); border-color:var(--pcf-orange-2); }
        .pcf-msg { color:#ff8a6a; font-size:11px; min-height:14px; }
        `;
        document.head.appendChild(st);
    }

    const dlg = document.createElement("dialog");
    dlg.className = "pcf-dlg";
    dlg.innerHTML = `
      <div class="pcf-header">
        <span class="pcf-dot"></span>
        <h3>Pixa Frame Editor</h3>
      </div>
      <div class="pcf-body">
        <div class="pcf-preview">
          <canvas id="pcf-canvas"></canvas>
        </div>
        <div class="pcf-controls">
          <label>Style
            <select id="pcf-style">
              <option value="none">none</option>
              <option value="wood">wood</option>
              <option value="gold">gold</option>
              <option value="silver">silver</option>
            </select>
          </label>
          <label>Frame width<span class="pcf-val" id="pcf-fw-val"></span>
            <input id="pcf-fw" type="range" min="0" max="300" step="1">
          </label>
          <label>Inner padding<span class="pcf-val" id="pcf-pad-val"></span>
            <input id="pcf-pad" type="range" min="0" max="200" step="1">
          </label>
          <label>Corner radius<span class="pcf-val" id="pcf-cr-val"></span>
            <input id="pcf-cr" type="range" min="0" max="400" step="1">
          </label>
          <label>Bevel<span class="pcf-val" id="pcf-bv-val"></span>
            <input id="pcf-bv" type="range" min="0" max="1" step="0.05">
          </label>
          <label>Tint
            <input id="pcf-tint" type="color">
          </label>
          <div style="flex:1;"></div>
          <div class="pcf-msg" id="pcf-msg"></div>
          <div class="pcf-buttons">
            <button class="pcf-save" id="pcf-save">Save</button>
            <button id="pcf-cancel">Cancel</button>
          </div>
        </div>
      </div>`;
    document.body.appendChild(dlg);
    dlg.showModal();

    const $ = (id) => dlg.querySelector(id);
    const ctx = $("#pcf-canvas").getContext("2d");

    $("#pcf-style").value = params.frame_style;
    $("#pcf-fw").value = params.frame_width;
    $("#pcf-pad").value = params.inner_padding;
    $("#pcf-cr").value = params.corner_radius;
    $("#pcf-bv").value = params.bevel;
    $("#pcf-tint").value = params.tint || "#ffffff";

    let img = null;
    const url = findUpstreamImageURL(node);
    if (url) {
        img = new Image();
        img.crossOrigin = "anonymous";
        img.onload = render;
        img.onerror = () => { $("#pcf-msg").textContent = "Failed to load upstream image."; };
        img.src = api.apiURL ? api.apiURL(url) : url;
    } else {
        $("#pcf-msg").textContent = "Connect a LoadImage upstream to preview.";
        // placeholder
        const c = document.createElement("canvas");
        c.width = 256; c.height = 256;
        const cc = c.getContext("2d");
        cc.fillStyle = "#444"; cc.fillRect(0, 0, 256, 256);
        cc.fillStyle = "#888"; cc.font = "16px sans-serif"; cc.fillText("no image", 90, 130);
        img = c;
        render();
    }

    function readParams() {
        params.frame_style   = $("#pcf-style").value;
        params.frame_width   = parseInt($("#pcf-fw").value);
        params.inner_padding = parseInt($("#pcf-pad").value);
        params.corner_radius = parseInt($("#pcf-cr").value);
        params.bevel         = parseFloat($("#pcf-bv").value);
        params.tint          = $("#pcf-tint").value;
        $("#pcf-fw-val").textContent  = params.frame_width;
        $("#pcf-pad-val").textContent = params.inner_padding;
        $("#pcf-cr-val").textContent  = params.corner_radius;
        $("#pcf-bv-val").textContent  = params.bevel.toFixed(2);
    }

    function render() {
        readParams();
        if (!img) return;
        drawFramed(ctx, img, params);
    }

    for (const id of ["#pcf-style","#pcf-fw","#pcf-pad","#pcf-cr","#pcf-bv","#pcf-tint"]) {
        $(id).addEventListener("input", render);
        $(id).addEventListener("change", render);
    }
    readParams();

    $("#pcf-save").onclick = () => {
        get("frame_style").value   = params.frame_style;
        get("frame_width").value   = params.frame_width;
        get("inner_padding").value = params.inner_padding;
        get("corner_radius").value = params.corner_radius;
        get("bevel").value         = params.bevel;
        get("tint").value          = params.tint;
        node.setDirtyCanvas(true, true);
        dlg.close();
        dlg.remove();
    };
    $("#pcf-cancel").onclick = () => { dlg.close(); dlg.remove(); };
}

app.registerExtension({
    name: "PixaTools.PixaCoolFrames",
    async beforeRegisterNodeDef(nodeType, nodeData) {
        if (nodeData.name !== "PixaCoolFrames") return;
        const orig = nodeType.prototype.onNodeCreated;
        nodeType.prototype.onNodeCreated = function () {
            const r = orig?.apply(this, arguments);
            this.addWidget("button", "Open Frame Editor", null, () => openEditor(this));
            return r;
        };
    },
});
