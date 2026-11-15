// Copia la app web (la misma que se publica en GitHub Pages) a la carpeta www, que es la que usa el proyecto de iPhone.
const fs = require("fs"), path = require("path");
const root = path.join(__dirname, ".."), out = path.join(root, "www");
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(path.join(out, "logo"), { recursive: true });
for (const f of ["index.html", "manifest.webmanifest"]) fs.copyFileSync(path.join(root, f), path.join(out, f));
for (const f of fs.readdirSync(path.join(root, "logo"))) fs.copyFileSync(path.join(root, "logo", f), path.join(out, "logo", f));
console.log("www lista");
