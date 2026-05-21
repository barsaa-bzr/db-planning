const fs = require('fs');

const csv = fs.readFileSync('DB & Flow draft(Sheet2).csv', 'utf8');
const lines = csv.split('\n').filter(line => line.trim() !== '');

const parsed = [];
for (let i = 1; i < lines.length; i++) {
    // Basic CSV parser assuming no commas inside quotes, or handle it carefully.
    // Looking at the data, it seems there are no quotes or commas inside fields. The text is separated by commas.
    // Wait, let's use a regex that handles basic splitting.
    const row = lines[i].split(',');
    if (row.length >= 4) {
        parsed.push({
            id: i,
            action: row[0].trim(),
            ourEnd: row[1].trim(),
            polarisEnd: row[2].trim(),
            response: row.slice(3).join(',').trim()
        });
    }
}

const groups = [
    { title: "1. Setup & Onboarding", start: 1, end: 11 },
    { title: "2. Scoring & Line Setup", start: 12, end: 18 },
    { title: "3. Origination Entry", start: 19, end: 24 },
    { title: "4. Core Polaris Loan Setup", start: 25, end: 28 },
    { title: "5. Disbursement & Execution", start: 29, end: 33 },
    { title: "6. Repayment, Refund & Reconciliation", start: 34, end: 49 },
    { title: "7. Global Rules & Handling", start: 50, end: 57 }
];

const groupedData = groups.map(g => ({
    title: g.title,
    items: parsed.filter(p => p.id >= g.start && p.id <= g.end)
}));

const html = `
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Lending / BNPL Flow</title>
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg: #0f172a;
            --surface: #1e293b;
            --surface-hover: #334155;
            --primary: #3b82f6;
            --secondary: #8b5cf6;
            --accent: #f43f5e;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
            --border: rgba(255, 255, 255, 0.1);
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            font-family: 'Outfit', sans-serif;
            background-color: var(--bg);
            color: var(--text-main);
            line-height: 1.6;
            overflow-x: hidden;
            background-image: 
                radial-gradient(circle at 15% 50%, rgba(59, 130, 246, 0.15) 0%, transparent 50%),
                radial-gradient(circle at 85% 30%, rgba(139, 92, 246, 0.15) 0%, transparent 50%);
            background-attachment: fixed;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 3rem 2rem;
        }

        header {
            text-align: center;
            margin-bottom: 4rem;
            animation: fadeInDown 1s ease-out;
        }

        h1 {
            font-size: 3.5rem;
            font-weight: 700;
            background: linear-gradient(135deg, var(--primary), var(--secondary), var(--accent));
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            margin-bottom: 1rem;
            letter-spacing: -1px;
        }

        .subtitle {
            font-size: 1.2rem;
            color: var(--text-muted);
            max-width: 600px;
            margin: 0 auto;
        }

        .nav-pills {
            display: flex;
            flex-wrap: wrap;
            gap: 1rem;
            justify-content: center;
            margin-bottom: 3rem;
            animation: fadeIn 1.2s ease-out;
        }

        .nav-pill {
            background: rgba(255, 255, 255, 0.05);
            border: 1px solid var(--border);
            padding: 0.5rem 1.2rem;
            border-radius: 999px;
            color: var(--text-muted);
            text-decoration: none;
            font-weight: 500;
            transition: all 0.3s ease;
            backdrop-filter: blur(10px);
            cursor: pointer;
        }

        .nav-pill:hover, .nav-pill.active {
            background: rgba(255, 255, 255, 0.1);
            color: #fff;
            transform: translateY(-2px);
            border-color: rgba(255,255,255,0.2);
            box-shadow: 0 4px 20px rgba(0,0,0,0.2);
        }

        .section-container {
            display: none;
            animation: fadeIn 0.5s ease-out;
        }
        
        .section-container.active {
            display: block;
        }

        .section-title {
            font-size: 2rem;
            font-weight: 600;
            margin-bottom: 2rem;
            display: flex;
            align-items: center;
            gap: 1rem;
            color: var(--text-main);
        }

        .section-title::after {
            content: '';
            flex-grow: 1;
            height: 1px;
            background: linear-gradient(90deg, var(--border), transparent);
        }

        .cards-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(350px, 1fr));
            gap: 1.5rem;
        }

        .card {
            background: rgba(30, 41, 59, 0.7);
            border: 1px solid var(--border);
            border-radius: 16px;
            padding: 1.5rem;
            transition: all 0.4s cubic-bezier(0.175, 0.885, 0.32, 1.275);
            backdrop-filter: blur(10px);
            position: relative;
            overflow: hidden;
            display: flex;
            flex-direction: column;
            gap: 1rem;
        }

        .card::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 4px;
            background: linear-gradient(90deg, var(--primary), var(--secondary));
            transform: scaleX(0);
            transform-origin: left;
            transition: transform 0.4s ease;
        }

        .card:hover {
            transform: translateY(-8px);
            box-shadow: 0 20px 40px rgba(0, 0, 0, 0.3);
            border-color: rgba(255,255,255,0.2);
        }

        .card:hover::before {
            transform: scaleX(1);
        }

        .card-header {
            display: flex;
            align-items: flex-start;
            justify-content: space-between;
            gap: 1rem;
        }

        .card-title {
            font-size: 1.25rem;
            font-weight: 600;
            color: #fff;
            line-height: 1.3;
        }

        .card-badge {
            background: rgba(59, 130, 246, 0.2);
            color: #60a5fa;
            font-size: 0.75rem;
            padding: 0.25rem 0.75rem;
            border-radius: 999px;
            font-weight: 600;
            white-space: nowrap;
        }

        .process-group {
            display: flex;
            flex-direction: column;
            gap: 0.5rem;
            flex-grow: 1;
        }

        .process-item {
            background: rgba(0, 0, 0, 0.2);
            border-radius: 8px;
            padding: 0.75rem 1rem;
            border: 1px solid rgba(255, 255, 255, 0.05);
        }

        .process-label {
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 1px;
            color: var(--text-muted);
            margin-bottom: 0.25rem;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }

        .process-label.polaris { color: #c084fc; }
        .process-label.response { color: #fb7185; }

        .process-content {
            font-size: 0.95rem;
            color: #e2e8f0;
        }

        .empty-text {
            color: #64748b;
            font-style: italic;
            font-size: 0.9rem;
        }

        @keyframes fadeInDown {
            from { opacity: 0; transform: translateY(-20px); }
            to { opacity: 1; transform: translateY(0); }
        }

        @keyframes fadeIn {
            from { opacity: 0; }
            to { opacity: 1; }
        }

        @media (max-width: 768px) {
            h1 { font-size: 2.5rem; }
            .cards-grid { grid-template-columns: 1fr; }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>Lending & BNPL Flow</h1>
            <p class="subtitle">Operational flow, control points, database tables, and API interactions for the Polaris system.</p>
        </header>

        <div class="nav-pills" id="nav">
            <!-- Navigation will be generated here -->
        </div>

        <div id="content">
            <!-- Content will be generated here -->
        </div>
    </div>

    <script>
        const data = ${JSON.stringify(groupedData)};

        const nav = document.getElementById('nav');
        const content = document.getElementById('content');

        function render() {
            // Render Navigation
            data.forEach((group, index) => {
                const btn = document.createElement('div');
                btn.className = \`nav-pill \${index === 0 ? 'active' : ''}\`;
                btn.textContent = group.title.replace(/^\\d+\\.\\s*/, '');
                btn.onclick = () => switchTab(index);
                nav.appendChild(btn);
            });

            // Render Content
            data.forEach((group, index) => {
                const section = document.createElement('div');
                section.className = \`section-container \${index === 0 ? 'active' : ''}\`;
                section.id = \`section-\${index}\`;

                let html = \`<h2 class="section-title">\${group.title}</h2><div class="cards-grid">\`;
                
                group.items.forEach(item => {
                    html += \`
                        <div class="card">
                            <div class="card-header">
                                <h3 class="card-title">\${item.action}</h3>
                                <span class="card-badge">Step \${item.id}</span>
                            </div>
                            
                            <div class="process-group">
                                \${renderProcessItem('Our Process', item.ourEnd, '')}
                                \${renderProcessItem('Polaris', item.polarisEnd, 'polaris')}
                                \${renderProcessItem('Response', item.response, 'response')}
                            </div>
                        </div>
                    \`;
                });

                html += \`</div>\`;
                section.innerHTML = html;
                content.appendChild(section);
            });
        }

        function renderProcessItem(label, text, className) {
            if (!text || text === '-' || text.toLowerCase() === 'no polaris call') {
                return \`
                    <div class="process-item">
                        <div class="process-label \${className}">\${label}</div>
                        <div class="empty-text">No action / None</div>
                    </div>
                \`;
            }
            return \`
                <div class="process-item">
                    <div class="process-label \${className}">\${label}</div>
                    <div class="process-content">\${text}</div>
                </div>
            \`;
        }

        function switchTab(index) {
            document.querySelectorAll('.nav-pill').forEach((el, i) => {
                el.classList.toggle('active', i === index);
            });
            document.querySelectorAll('.section-container').forEach((el, i) => {
                el.classList.toggle('active', i === index);
            });
        }

        render();
    </script>
</body>
</html>
`;

fs.writeFileSync('fancy_flow.html', html);
console.log('fancy_flow.html created successfully!');
