// Console harness: feeds requests to the CAS thread and prints the results
// as flattened text. Not installed; handy after touching cas.cpp.
#include "../src/cas.h"
#include <QCoreApplication>
#include <QTimer>
#include <cstdio>

static QString flat(const MPtr &n)
{
    if (!n) return "";
    QString s;
    auto kids = [&](int i) { return i < int(n->c.size()) ? flat(n->c[i]) : QString(); };
    switch (n->kind) {
    case MNode::Row: for (auto &c : n->c) s += flat(c); return s;
    case MNode::Op: return n->n == 1 ? n->text : " " + n->text + " ";
    case MNode::Frac: return "{" + kids(0) + "}/{" + kids(1) + "}";
    case MNode::Pow: return kids(0) + "^{" + kids(1) + "}";
    case MNode::Sub: return kids(0) + "_{" + kids(1) + "}";
    case MNode::Sqrt: return (n->c.size() > 1 && n->c[1] ? "root" + kids(1) : QString("√")) + "{" + kids(0) + "}";
    case MNode::Paren: return QString(n->text[0]) + kids(0) + QString(n->text.size() > 1 ? n->text[1] : n->text[0]);
    case MNode::Conj: return "conj{" + kids(0) + "}";
    case MNode::Matrix: {
        s = "[";
        for (size_t i = 0; i < n->c.size(); ++i) s += (i ? (i % n->n ? ", " : "; ") : "") + flat(n->c[i]);
        return s + "]";
    }
    case MNode::BigOp: return n->text + "_{" + kids(1) + "}^{" + kids(2) + "} " + kids(0);
    case MNode::Under: return kids(0) + "_{" + kids(1) + "} ";
    case MNode::Space: return " ";
    default: return n->text;
    }
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    Cas cas;
    cas.setDefinitions({});
    std::vector<Request> reqs;
    auto ev = [&](const char *t, bool deg = false) { Request r; r.kind = Request::Eval; r.text = QString::fromUtf8(t); r.deg = deg; reqs.push_back(r); };
    auto so = [&](const char *t, bool cx = false) { Request r; r.kind = Request::Solve; r.lines = QString::fromUtf8(t).split('\n'); r.params["complex"] = cx; reqs.push_back(r); };
    auto ca = [&](QVariantMap m) { Request r; r.kind = Request::Calc; r.params = m; reqs.push_back(r); };
    auto pl = [&](const char *t) { Request r; r.kind = Request::Plot; r.lines = QString::fromUtf8(t).split('\n'); reqs.push_back(r); };

    QString mode = argc > 1 ? argv[1] : "";
    if (mode == "grad") { ca({{"op", "grad"}, {"f", "x^3 - 3x + y^2"}}); }
    else if (mode == "plot") { pl("sen(x)/x\ny = x^3 - 3x\nx^2 + y^2 = 9\ny > x^2 - 2\n(cos(3t), sen(2t))\nfoo("); pl("sen(x)·cos(y)\nx^2 + y^2 + z^2 = 9\n(cos(t), sen(t), t/5)\nx^2"); pl("(z^2 - 1)/(z^2 + 1)"); }
    else for (int i = 1; i < argc; ++i) ev(argv[i]);
    if (argc == 1) {
        ev("2+3*4"); ev("1/3+1/6"); ev("2 sen(30°)", true); ev("sin(pi/6)"); ev("sen x"); ev("√2·√8"); ev("∛(-8)");
        ev("(3+4i)/(1-i)"); ev("abs(3+4i)"); ev("e^(i·π)"); ev("polar(2, 60)", true); ev("100!"); ev("360"); ev("97");
        ev("log(1000)"); ev("log(8, 2)"); ev("ln(e^3)"); ev("nCr(10,3)"); ev("mod(17,5)"); ev("2xy + 3x(x+1)"); ev("(x+1)^3");
        ev("a = 5"); ev("a^2 + 1"); ev("f(x) = x^2 + 1"); ev("f(3)"); ev("ans + 1"); ev("x^2 - 5x + 6 = 0"); ev("1e-5*3"); ev("0.1+0.2");
        ev("sin^2 x + cos^2 x"); ev("[[1,2],[3,4]]^-1"); ev("2^100"); ev("sqrt(-4)"); ev("1/0"); ev("2+"); ev("3 > 2");
        so("x^2 - 5x + 6 = 0"); so("2 sen(x) = 1"); so("x^4 = 16", true); so("x^2 + 1 = 0"); so("cos(x) = x");
        so("2x + 3y = 7\nx - y = 1"); so("x + y + z = 1\n2x + 2y + 2z = 2"); so("x + y = 1\nx + y = 3"); so("x^2 + y^2 = 25\ny = x + 1");
        so("(x - 1)/(x + 2) >= 0"); so("x^2 < 9\n2x + 1 > 0"); so("abs(x-1) <= 2"); so("1 < 2x + 1 <= 7");
        so("x + y <= 6\nx - y >= -2\nx >= 0\ny >= 0"); so("x^2 > 4");
        ca({{"op", "diff"}, {"f", "x^3·sen(x)"}, {"order", 1}}); ca({{"op", "diff"}, {"f", "x^2 y^3"}, {"var", "x,y"}});
        ca({{"op", "int"}, {"f", "x^2·e^x"}}); ca({{"op", "int"}, {"f", "e^(-x^2)"}}); ca({{"op", "int"}, {"f", "sqrt(1+x^3)"}});
        ca({{"op", "defint"}, {"f", "sen(x)^2"}, {"a", "0"}, {"b", "pi"}}); ca({{"op", "defint"}, {"f", "e^(-x^2)"}, {"a", "-inf"}, {"b", "inf"}});
        ca({{"op", "defint"}, {"f", "sqrt(1+x^3)"}, {"a", "0"}, {"b", "1"}});
        ca({{"op", "double"}, {"f", "x·y^2"}, {"a", "0"}, {"b", "1"}, {"c", "0"}, {"d", "2"}});
        ca({{"op", "limit"}, {"f", "sen(x)/x"}, {"point", "0"}, {"dir", 0}}); ca({{"op", "limit"}, {"f", "1/x"}, {"point", "0"}, {"dir", 0}});
        ca({{"op", "limit"}, {"f", "(1+1/x)^x"}, {"point", "inf"}, {"dir", 0}});
        ca({{"op", "taylor"}, {"f", "cos(x)"}, {"point", "0"}, {"order", 6}}); ca({{"op", "sum"}, {"f", "1/n^2"}, {"a", "1"}, {"b", "inf"}});
        ca({{"op", "grad"}, {"f", "x^3 - 3x + y^2"}});
        pl("sen(x)/x\ny = x^3 - 3x\nx^2 + y^2 = 9\ny > x^2 - 2\n(cos(3t), sen(2t))\nfoo(");
        pl("sen(x)·cos(y)\nx^2 + y^2 + z^2 = 9\n(cos(t), sen(t), t/5)\nx^2");
        pl("(z^2 - 1)/(z^2 + 1)");
    }
    size_t done = 0;
    std::map<int, Request> byId;
    QObject::connect(&cas, &Cas::finished, [&](const Response &r) {
        const Request &q = byId[r.id];
        QString in = q.kind == Request::Eval ? q.text : q.kind == Request::Calc ? q.params.value("op").toString() + ": " + q.params.value("f").toString() : q.lines.join(" | ");
        printf("\n>>> %s\n", in.toUtf8().constData());
        if (!r.ok) printf("   ERROR: %s\n", r.error.toUtf8().constData());
        for (auto &it : r.items)
            printf("   %s%s\n      text: %s\n", it.caption.isEmpty() ? "" : ("[" + it.caption + "] ").toUtf8().constData(),
                   flat(it.formula).toUtf8().constData(), it.text.toUtf8().constData());
        if (r.plot) {
            QStringList k;
            static const char *names[] = {"Func", "Implicit", "Region", "Param2", "Surface", "Param3", "Domain", "XBand", "Points", "Fill", "Implicit3"};
            for (auto &s : r.plot->series) k << QString(names[s.kind]) + (s.p.empty() || s.p[0].valid ? "" : "(INVALID)");
            printf("   plot%s: %s  x[%g,%g]\n", r.plot->is3D ? "3D" : "", k.join(", ").toUtf8().constData(), r.plot->xmin, r.plot->xmax);
        }
        for (int i = 0; i < r.itemErrors.size(); ++i)
            if (!r.itemErrors[i].isEmpty()) printf("   line %d: %s\n", i, r.itemErrors[i].toUtf8().constData());
        if (++done == reqs.size()) app.quit();
    });
    for (auto &r : reqs) {
        int id = cas.submit(r);
        byId[id] = r;
    }
    QTimer::singleShot(60000, &app, [&] { printf("TIMEOUT\n"); app.quit(); });
    return app.exec();
}
