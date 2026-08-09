(function () {
    "use strict";

    const documentationVersion = "v10.0.0";

    const pages = [
        ["index.html", "Overview"],
        ["getting-started.html", "Getting started"],
        ["bot-modes.html", "Bot modes"],
        ["main-window.html", "Main window"],
        ["packs-and-card-detection.html", "Packs, Detection & S4T"],
        ["accounts-and-trading.html", "Accounts & trading"],
        ["group-and-discord.html", "Group & Discord"],
        ["tools-and-system.html", "Tools & system"],
        ["troubleshooting.html", "Troubleshooting"],
        ["faq.html", "FAQ"],
    ];

    const header = document.querySelector("[data-docs-header]");
    if (header) {
        header.innerHTML = `
            <div class="topbar-inner">
                <a class="brand" href="index.html">
                    <span class="brand-mark">PTCGPB</span> User Guide
                    <span class="version">${documentationVersion}</span>
                </a>
                <button
                    class="menu-button"
                    type="button"
                    data-menu-button
                    aria-expanded="false"
                    aria-label="Open documentation menu"
                >Menu</button>
            </div>`;
    }

    document.querySelectorAll("[data-docs-version]").forEach(function (node) {
        node.textContent = documentationVersion;
    });

    const current = location.pathname.split("/").pop() || "index.html";
    const sidebar = document.querySelector("[data-docs-nav]");
    if (sidebar) {
        const links = pages
            .map(([href, label]) => {
                const active = href === current ? ' aria-current="page"' : "";
                return `<a href="${href}"${active}>${label}</a>`;
            })
            .join("");
        sidebar.innerHTML = `<p class="nav-label">User guide</p><nav aria-label="Documentation">${links}</nav>`;
    }

    const menu = document.querySelector("[data-menu-button]");
    if (menu && sidebar) {
        menu.addEventListener("click", function () {
            const open = sidebar.classList.toggle("open");
            menu.setAttribute("aria-expanded", String(open));
        });
        sidebar.addEventListener("click", function (event) {
            if (event.target.closest("a")) {
                sidebar.classList.remove("open");
                menu.setAttribute("aria-expanded", "false");
            }
        });
    }

    document.querySelectorAll("[data-year]").forEach(function (node) {
        node.textContent = new Date().getFullYear();
    });
})();
