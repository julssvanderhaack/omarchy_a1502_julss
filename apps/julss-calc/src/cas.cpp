// Giac must come before any Qt header: Qt's keyword macros (emit, slots...)
// would otherwise leak into Giac's headers.
#include <giac/config.h>
#include <giac/giac.h>

#include "cas.h"
#include <QHash>
#include <QRegularExpression>
#include <QSet>
#include <algorithm>
#include <clocale>
#include <functional>
#include <map>
#include <sstream>

using giac::gen;
using giac::vecteur;

namespace {

struct CasError : std::runtime_error {
    explicit CasError(const QString &m) : std::runtime_error(m.toStdString()) {}
};

enum { P_REL = 0, P_SUM = 1, P_PROD = 2, P_FRAC = 3, P_POW = 4, P_ATOM = 5 };

// ================================================================ rewriting
// Turns what people type ("2 sen x + raiz(9)·π", "sin^2 x", "30°") into
// Giac syntax. Works on tokens so that implicit products and implicit
// function application can be inserted safely.

struct Tok {
    enum T { Num, Id, Op, LP, RP, Comma, Space, Post, Other } t;
    QString s;
};

QString unicodeToAscii(QString s)
{
    static const std::pair<const char *, const char *> rep[] = {
        {"×", "*"}, {"·", "*"}, {"⋅", "*"}, {"÷", "/"}, {"−", "-"}, {"–", "-"},
        {"π", " pi "}, {"∞", " inf "}, {"√", " sqrt "}, {"∛", " cbrt "},
        {"²", "^2"}, {"³", "^3"}, {"≤", "<="}, {"≥", ">="}, {"≠", "!="}, {"ⅈ", "i"},
        {"**", "^"}, {";", ","},
    };
    for (auto &r : rep) s.replace(QString::fromUtf8(r.first), QString::fromUtf8(r.second));
    return s;
}

std::vector<Tok> lex(const QString &in)
{
    std::vector<Tok> t;
    const int n = in.size();
    int i = 0;
    while (i < n) {
        QChar c = in[i];
        if (c.isSpace()) {
            while (i < n && in[i].isSpace()) ++i;
            t.push_back({Tok::Space, " "});
        } else if (c.isDigit() || (c == '.' && i + 1 < n && in[i + 1].isDigit())) {
            int b = i;
            while (i < n && (in[i].isDigit() || in[i] == '.')) ++i;
            if (i < n && (in[i] == 'e' || in[i] == 'E')) {
                int j = i + 1;
                if (j < n && (in[j] == '+' || in[j] == '-')) ++j;
                if (j < n && in[j].isDigit()) {
                    i = j;
                    while (i < n && in[i].isDigit()) ++i;
                }
            }
            t.push_back({Tok::Num, in.mid(b, i - b)});
        } else if (c.isLetter() || c == '_') {
            int b = i;
            while (i < n && (in[i].isLetterOrNumber() || in[i] == '_')) ++i;
            t.push_back({Tok::Id, in.mid(b, i - b)});
        } else if (c == '(' || c == '[' || c == '{') {
            t.push_back({Tok::LP, QString(c)}), ++i;
        } else if (c == ')' || c == ']' || c == '}') {
            t.push_back({Tok::RP, QString(c)}), ++i;
        } else if (c == ',') {
            t.push_back({Tok::Comma, ","}), ++i;
        } else if (c == QChar(0x00B0)) {
            t.push_back({Tok::Post, QString(c)}), ++i;
        } else if (c == '!') {
            if (i + 1 < n && in[i + 1] == '=') t.push_back({Tok::Op, "!="}), i += 2;
            else t.push_back({Tok::Post, "!"}), ++i;
        } else {
            static const char *two[] = {"<=", ">=", "==", ":=", "->"};
            bool done = false;
            for (auto op : two) {
                if (in.mid(i, 2) == QLatin1String(op)) {
                    t.push_back({Tok::Op, op});
                    i += 2;
                    done = true;
                    break;
                }
            }
            if (done) continue;
            if (QString("+-*/^=<>%").contains(c)) t.push_back({Tok::Op, QString(c)});
            else t.push_back({Tok::Other, QString(c)});
            ++i;
        }
    }
    return t;
}

const QHash<QString, QString> &aliases()
{
    static const QHash<QString, QString> a = {
        {"sen", "sin"}, {"tg", "tan"}, {"cotg", "cot"}, {"cosec", "csc"},
        {"arcsen", "asin"}, {"asen", "asin"}, {"arcsin", "asin"}, {"arccos", "acos"},
        {"arctg", "atan"}, {"arctan", "atan"}, {"senh", "sinh"}, {"tgh", "tanh"},
        {"argsenh", "asinh"}, {"asenh", "asinh"}, {"arcsenh", "asinh"}, {"argcosh", "acosh"},
        {"argtgh", "atanh"}, {"raiz", "sqrt"}, {QString::fromUtf8("raíz"), "sqrt"},
        {"mod", "irem"}, {"mcd", "gcd"}, {"mcm", "lcm"}, {"fact", "factorial"},
        {"nCr", "comb"}, {"ncr", "comb"}, {"nPr", "perm"}, {"npr", "perm"},
        {"derivada", "diff"}, {"integral", "integrate"}, {"limite", "limit"},
        {QString::fromUtf8("límite"), "limit"}, {"sumatorio", "sum"}, {"infinito", "inf"},
        {"ans", "ans_"}, {"primo", "isprime"}, {"factoriza", "factor"},
        {"simplifica", "simplify"}, {"desarrolla", "expand"}, {"resuelve", "solve"},
        {"Re", "re"}, {"Im", "im"}, {"conjugado", "conj"}, {"gamma", "Gamma"},
    };
    return a;
}

class Rewriter {
public:
    Rewriter(std::function<bool(const QString &)> isFunc, bool deg) : m_isFunc(std::move(isFunc)), m_deg(deg) {}

    QString run(const QString &in)
    {
        t = lex(unicodeToAscii(in));
        return rw(0, int(t.size()));
    }

private:
    std::vector<Tok> t;
    std::function<bool(const QString &)> m_isFunc;
    bool m_deg;

    static QString mapId(const QString &s) { return aliases().value(s, s); }
    bool isFunc(const QString &mapped) const
    {
        static const QSet<QString> special = {"log", "cbrt", "polar"};
        return special.contains(mapped) || m_isFunc(mapped);
    }
    int skipSp(int i, int e) const
    {
        while (i < e && t[i].t == Tok::Space) ++i;
        return i;
    }
    int match(int i, int e) const
    {
        int depth = 0;
        for (int k = i; k < e; ++k) {
            if (t[k].t == Tok::LP) ++depth;
            else if (t[k].t == Tok::RP && --depth == 0) return k;
        }
        return -1;
    }
    int commas(int b, int e) const
    {
        int depth = 0, n = 0;
        for (int k = b; k < e; ++k) {
            if (t[k].t == Tok::LP) ++depth;
            else if (t[k].t == Tok::RP) --depth;
            else if (t[k].t == Tok::Comma && depth == 0) ++n;
        }
        return n;
    }
    bool startsAtom(int j, int e) const
    {
        if (j >= e) return false;
        if (t[j].t == Tok::Num || t[j].t == Tok::Id) return true;
        if (t[j].t == Tok::LP && t[j].s == "(") return true;
        if (t[j].t == Tok::Op && t[j].s == "-") return startsAtom(skipSp(j + 1, e), e);
        return false;
    }
    // End of the argument of an implicit call such as "sen 2x^2".
    int atomEnd(int j, int e) const
    {
        int k = j;
        if (t[k].t == Tok::Op && t[k].s == "-") k = skipSp(k + 1, e);
        if (k >= e) return e;
        if (t[k].t == Tok::Num) {
            ++k;
            while (k < e && t[k].t == Tok::Id && !isFunc(mapId(t[k].s))) ++k;
        } else if (t[k].t == Tok::Id) {
            if (isFunc(mapId(t[k].s))) {
                int j2 = skipSp(k + 1, e);
                if (j2 < e && t[j2].t == Tok::LP) {
                    int m = match(j2, e);
                    k = m < 0 ? e : m + 1;
                } else if (startsAtom(j2, e)) {
                    k = atomEnd(j2, e);
                } else {
                    ++k;
                }
            } else {
                ++k;
            }
        } else if (t[k].t == Tok::LP) {
            int m = match(k, e);
            k = m < 0 ? e : m + 1;
        }
        while (k < e) {
            if (t[k].t == Tok::Post) { ++k; continue; }
            if (t[k].t == Tok::Op && t[k].s == "^") {
                int p = k + 1;
                if (p < e && t[p].t == Tok::Op && t[p].s == "-") ++p;
                if (p < e && (t[p].t == Tok::Num || t[p].t == Tok::Id)) { k = p + 1; continue; }
                if (p < e && t[p].t == Tok::LP) {
                    int m = match(p, e);
                    k = m < 0 ? e : m + 1;
                    continue;
                }
            }
            break;
        }
        return k;
    }

    QString call(const QString &name, const QString &inner, int ncommas) const
    {
        if (name == "log") return ncommas == 0 ? "log10(" + inner + ")" : "logb(" + inner + ")";
        if (name == "cbrt") return "surd(" + inner + ",3)";
        if (name == "polar") {
            QStringList rt = splitTop(inner);
            if (rt.size() == 2) return "((" + rt[0] + ")*(cos(" + rt[1] + ")+i*sin(" + rt[1] + ")))";
        }
        return name + "(" + inner + ")";
    }

    static QStringList splitTop(const QString &s)
    {
        QStringList out;
        int depth = 0, start = 0;
        for (int i = 0; i < s.size(); ++i) {
            if (s[i] == '(' || s[i] == '[') ++depth;
            else if (s[i] == ')' || s[i] == ']') --depth;
            else if (s[i] == ',' && depth == 0) out << s.mid(start, i - start), start = i + 1;
        }
        out << s.mid(start);
        return out;
    }

    QString rw(int b, int e)
    {
        QString out;
        bool prevValue = false;
        int i = b;
        while (i < e) {
            const Tok &k = t[i];
            switch (k.t) {
            case Tok::Space: ++i; break;
            case Tok::Num:
                if (prevValue) out += '*';
                out += k.s;
                prevValue = true;
                ++i;
                break;
            case Tok::Post:
                if (k.s == "!") out += "!";
                else if (!m_deg) out += "*(pi/180)";
                prevValue = true;
                ++i;
                break;
            case Tok::LP: {
                int m = match(i, e);
                if (m < 0) {
                    out += k.s;
                    prevValue = false;
                    ++i;
                    break;
                }
                if (prevValue && k.s == "(") out += '*';
                out += k.s + rw(i + 1, m) + t[m].s;
                prevValue = true;
                i = m + 1;
                break;
            }
            case Tok::RP: out += k.s; prevValue = true; ++i; break;
            case Tok::Comma: out += ','; prevValue = false; ++i; break;
            case Tok::Op:
            case Tok::Other: out += k.s; prevValue = false; ++i; break;
            case Tok::Id: i = ident(i, e, out, prevValue); break;
            }
        }
        return out;
    }

    int ident(int i, int e, QString &out, bool &prevValue)
    {
        static const QSet<QString> words = {"and", "or", "not", "xor"};
        QString name = mapId(t[i].s);
        if (words.contains(name)) {
            out += " " + name + " ";
            prevValue = false;
            return i + 1;
        }
        if (isFunc(name)) {
            int j = skipSp(i + 1, e);
            QString expo;
            // sin^2 x  ->  (sin(x))^2
            if (j < e && t[j].t == Tok::Op && t[j].s == "^") {
                int k2 = skipSp(j + 1, e);
                int ae = k2;
                if (k2 < e && (t[k2].t == Tok::Num || t[k2].t == Tok::Id)) ae = k2 + 1;
                else if (k2 < e && t[k2].t == Tok::LP) ae = match(k2, e) + 1;
                if (ae > k2) {
                    int a2 = skipSp(ae, e);
                    if (startsAtom(a2, e)) {
                        expo = rw(k2, ae);
                        j = a2;
                    }
                }
            }
            QString c;
            int next;
            if (j < e && t[j].t == Tok::LP && t[j].s == "(") {
                int m = match(j, e);
                if (m < 0) m = e;
                c = call(name, rw(j + 1, m), commas(j + 1, m));
                next = std::min(m + 1, e);
            } else if (startsAtom(j, e)) {
                int ae = atomEnd(j, e);
                c = call(name, rw(j, ae), 0);
                next = ae;
            } else {
                c = name;
                next = i + 1;
            }
            if (prevValue) out += '*';
            out += expo.isEmpty() ? c : "(" + c + ")^(" + expo + ")";
            prevValue = true;
            return next;
        }
        // "xy" -> x*y, but leave real names alone
        static const QRegularExpression xyz("^[xyzt]{2,4}$");
        if (xyz.match(name).hasMatch()) {
            QStringList parts;
            for (QChar ch : name) parts << QString(ch);
            name = parts.join('*');
        }
        if (prevValue) out += '*';
        out += name;
        prevValue = true;
        return i + 1;
    }
};

// Top-level split on relational operators: "1 < x <= 3" -> parts + ops.
struct RelSplit {
    QStringList parts;
    QStringList ops;
};

RelSplit splitRel(const QString &raw)
{
    QString s = unicodeToAscii(raw);
    RelSplit r;
    int depth = 0, start = 0;
    for (int i = 0; i < s.size(); ++i) {
        QChar c = s[i];
        if (c == '(' || c == '[' || c == '{') ++depth;
        else if (c == ')' || c == ']' || c == '}') --depth;
        if (depth != 0) continue;
        QString op;
        QString two = s.mid(i, 2);
        if (two == "<=" || two == ">=" || two == "!=" || two == "==" || two == ":=") op = two;
        else if (c == '<' || c == '>' || c == '=') op = QString(c);
        if (op.isEmpty()) continue;
        if (op == "==") op = "=";
        r.parts << s.mid(start, i - start).trimmed();
        r.ops << op;
        i += op.size() - (op.size() == 1 && two == "==" ? 0 : 1);
        if (two == "==") ++i;
        start = i + 1;
    }
    r.parts << s.mid(start).trimmed();
    return r;
}

QString relSymbol(const QString &op)
{
    if (op == "<=") return QString::fromUtf8("≤");
    if (op == ">=") return QString::fromUtf8("≥");
    if (op == "!=") return QString::fromUtf8("≠");
    return op;
}

const QHash<QString, QString> &displayNames()
{
    static const QHash<QString, QString> d = {
        {"sin", "sen"}, {"tan", "tg"}, {"cot", "cotg"}, {"csc", "cosec"},
        {"asin", "arcsen"}, {"acos", "arccos"}, {"atan", "arctg"},
        {"sinh", "senh"}, {"tanh", "tgh"}, {"asinh", "argsenh"}, {"acosh", "argcosh"},
        {"atanh", "argtgh"}, {"log", "ln"}, {"log10", "log"}, {"re", "Re"}, {"im", "Im"},
        {"sign", "sgn"}, {"Gamma", QString::fromUtf8("Γ")}, {"gcd", "mcd"}, {"lcm", "mcm"},
        {"julpolar", "polar"}, {"ans_", "ans"},
    };
    return d;
}

const QHash<QString, QString> &greek()
{
    static const QHash<QString, QString> g = {
        {"pi", QString::fromUtf8("π")}, {"infinity", QString::fromUtf8("∞")},
        {"euler_gamma", QString::fromUtf8("γ")}, {"alpha", QString::fromUtf8("α")},
        {"beta", QString::fromUtf8("β")}, {"delta", QString::fromUtf8("δ")},
        {"epsilon", QString::fromUtf8("ε")}, {"theta", QString::fromUtf8("θ")},
        {"lambda", QString::fromUtf8("λ")}, {"mu", QString::fromUtf8("μ")},
        {"rho", QString::fromUtf8("ρ")}, {"sigma", QString::fromUtf8("σ")},
        {"tau", QString::fromUtf8("τ")}, {"phi", QString::fromUtf8("φ")},
        {"omega", QString::fromUtf8("ω")}, {"Delta", QString::fromUtf8("Δ")},
        {"Omega", QString::fromUtf8("Ω")}, {"Phi", QString::fromUtf8("Φ")},
        {"ans_", "ans"}, {"n_0", "n"}, {"n_1", "k"}, {"n_2", "m"}, {"julpolar", "polar"},
    };
    return g;
}

bool isNumType(const gen &g)
{
    return g.type == giac::_INT_ || g.type == giac::_ZINT || g.type == giac::_DOUBLE_ ||
           g.type == giac::_REAL || g.type == giac::_FRAC;
}

QString fmtDouble(double d, int digits)
{
    if (d == 0) return "0";
    if (std::isinf(d)) return d > 0 ? QString::fromUtf8("∞") : QString::fromUtf8("-∞");
    return QString::number(d, 'g', std::clamp(digits, 1, 17));
}

MPtr unaryOp(const QString &t) { auto m = std::make_shared<MNode>(); m->kind = MNode::Op; m->text = t; m->n = 1; return m; }
MPtr unaryMinus() { return unaryOp(QString::fromUtf8("−")); }

// "1.5e+20" -> 1.5·10²⁰
MPtr numberNode(const QString &s)
{
    int e = s.indexOf(QRegularExpression("[eE]"));
    if (e < 0) return M::num(s);
    QString mant = s.left(e), ex = s.mid(e + 1);
    if (ex.startsWith('+')) ex.remove(0, 1);
    bool negEx = ex.startsWith('-');
    if (negEx) ex.remove(0, 1);
    while (ex.size() > 1 && ex.startsWith('0')) ex.remove(0, 1);
    MPtr exn = negEx ? M::row({unaryMinus(), M::num(ex)}) : M::num(ex);
    if (mant == "1") return M::pow(M::num("10"), exn);
    return M::row({M::num(mant), M::op(QString::fromUtf8("·")), M::pow(M::num("10"), exn)});
}


MPtr joinNodes(const std::vector<MPtr> &v, const QString &sep)
{
    std::vector<MPtr> r;
    for (size_t i = 0; i < v.size(); ++i) {
        if (i) {
            r.push_back(M::text(sep));
            r.push_back(M::space(4));
        }
        r.push_back(v[i]);
    }
    return M::row(r);
}

bool startsWithNum(const MPtr &n)
{
    if (!n) return false;
    if (n->kind == MNode::Num) return true;
    if ((n->kind == MNode::Row || n->kind == MNode::Pow || n->kind == MNode::Sub) && !n->c.empty())
        return startsWithNum(n->c[0]);
    return false;
}

bool startsWithVar(const MPtr &n)
{
    if (!n) return false;
    if (n->kind == MNode::Var) return true;
    if ((n->kind == MNode::Row || n->kind == MNode::Pow || n->kind == MNode::Sub) && !n->c.empty()) return startsWithVar(n->c[0]);
    return false;
}

QString cleanError(QString m)
{
    m = m.trimmed();
    if (m.contains("interruption", Qt::CaseInsensitive)) return QString::fromUtf8("Cálculo cancelado.");
    if (m.contains("Division by 0", Qt::CaseInsensitive)) return QString::fromUtf8("División entre cero.");
    if (m.contains("Bad Argument Type", Qt::CaseInsensitive)) return QString::fromUtf8("Tipo de argumento no válido.");
    if (m.contains("Bad Argument Value", Qt::CaseInsensitive)) return QString::fromUtf8("Valor de argumento no válido.");
    if (m.contains("Too few arguments", Qt::CaseInsensitive)) return QString::fromUtf8("Faltan argumentos.");
    if (m.startsWith("Error: ")) m = m.mid(7);
    return m;
}

} // namespace

// ================================================================== engine
class CasEngine {
public:
    CasEngine()
    {
        giac::logptr(&m_null, &m_ctx);
        giac::approx_mode(false, &m_ctx);
    }

    void define(const QString &src)
    {
        try {
            run(src);
            QRegularExpression fn("^\\s*([A-Za-z_]\\w*)\\s*\\(");
            auto m = fn.match(src);
            if (m.hasMatch()) m_userFuncs.insert(m.captured(1));
        } catch (...) {
        }
    }

    Response handle(const Request &rq)
    {
        giac::ctrl_c = false;
        giac::interrupted = false;
        Response r;
        r.id = rq.id;
        r.kind = rq.kind;
        m_digits = rq.digits;
        giac::angle_radian(!(rq.deg && rq.kind == Request::Eval), &m_ctx);
        giac::complex_mode(false, &m_ctx);
        try {
            switch (rq.kind) {
            case Request::Eval: evaluate(rq, r); break;
            case Request::Preview: preview(rq, r); break;
            case Request::Solve: solveRequest(rq, r); break;
            case Request::Calc: calculus(rq, r); break;
            case Request::Plot: plot(rq, r); break;
            case Request::Define: define(rq.text); break;
            case Request::Undefine:
                run("purge(" + rq.text + ")");
                m_userFuncs.remove(rq.text);
                break;
            case Request::Reset: break;
            }
        } catch (const std::exception &e) {
            r.ok = false;
            r.error = cleanError(QString::fromUtf8(e.what()));
            if (giac::interrupted) r.error = QString::fromUtf8("Cálculo cancelado.");
        }
        giac::ctrl_c = false;
        giac::interrupted = false;
        giac::angle_radian(true, &m_ctx);
        return r;
    }

private:
    giac::context m_ctx;
    std::ostream m_null{nullptr};   // swallows Giac's log chatter
    QSet<QString> m_userFuncs;
    QHash<QString, bool> m_funcCache;
    int m_digits = 12;

    // ------------------------------------------------------------ basics
    bool isFunction(const QString &name)
    {
        if (m_userFuncs.contains(name)) return true;
        if (name.size() == 1) return false;
        static const QSet<QString> notFuncs = {"pi", "inf", "infinity", "ans_", "e", "i", "euler_gamma"};
        if (notFuncs.contains(name)) return false;
        auto it = m_funcCache.find(name);
        if (it != m_funcCache.end()) return *it;
        bool f = false;
        try {
            giac::first_error_line(0, &m_ctx);
            gen g(name.toStdString(), &m_ctx);
            f = g.type == giac::_FUNC;
        } catch (...) {
        }
        m_funcCache.insert(name, f);
        return f;
    }

    QString prep(const QString &s, bool deg = false)
    {
        Rewriter rw([this](const QString &n) { return isFunction(n); }, deg);
        return rw.run(s);
    }

    gen parse(const QString &giacSrc)
    {
        if (giacSrc.trimmed().isEmpty()) throw CasError(QString::fromUtf8("Expresión vacía."));
        int depth = 0;
        for (QChar c : giacSrc) {
            if (c == '(' || c == '[') ++depth;
            else if (c == ')' || c == ']') --depth;
            if (depth < 0) throw CasError(QString::fromUtf8("Sobra un paréntesis de cierre."));
        }
        if (depth > 0) throw CasError(depth == 1 ? QString::fromUtf8("Falta cerrar un paréntesis.")
                                                 : QString::fromUtf8("Faltan %1 paréntesis por cerrar.").arg(depth));
        giac::first_error_line(0, &m_ctx);
        gen g(giacSrc.toStdString(), &m_ctx);
        if (giac::first_error_line(&m_ctx) > 0) {
            QString tok = QString::fromStdString(giac::error_token_name(&m_ctx));
            if (tok.isEmpty() || tok == "end of input")
                throw CasError(QString::fromUtf8("Expresión incompleta."));
            throw CasError(QString::fromUtf8("Error de sintaxis cerca de «%1».").arg(tok));
        }
        return g;
    }

    gen ev(const gen &g)
    {
        gen r = giac::eval(g, 1, &m_ctx);
        if (r.type == giac::_STRNG) {
            QString s = QString::fromStdString(*r._STRNGptr);
            if (s.startsWith("Error", Qt::CaseInsensitive)) throw CasError(cleanError(s));
        }
        if (r.type == giac::_VECT && !r._VECTptr->empty() && r._VECTptr->front().type == giac::_STRNG) {
            QString s = QString::fromStdString(*r._VECTptr->front()._STRNGptr);
            if (s.contains("not allowed") || s.startsWith("Error")) throw CasError(cleanError(s));
        }
        return r;
    }

    gen run(const QString &giacSrc) { return ev(parse(giacSrc)); }
    gen user(const QString &raw, bool deg = false) { return ev(parse(prep(raw, deg))); }
    QString P(const gen &g) { return QString::fromStdString(g.print(&m_ctx)).replace("ans_", "ans"); }
    QString tex(const gen &g) { return QString::fromStdString(giac::gen2tex(g, &m_ctx)); }
    gen call(const QString &f, const gen &g) { return run(f + "(" + P(g) + ")"); }

    double dv(const gen &g)
    {
        try {
            gen f = giac::evalf_double(g, 1, &m_ctx);
            if (f.type == giac::_DOUBLE_) return f._DOUBLE_val;
            if (f.type == giac::_INT_) return f.val;
        } catch (...) {
        }
        return NAN;
    }

    bool numericValue(const gen &g, std::complex<double> &out)
    {
        try {
            gen f = giac::evalf_double(g, 1, &m_ctx);
            if (f.type == giac::_DOUBLE_) { out = f._DOUBLE_val; return true; }
            if (f.type == giac::_INT_) { out = f.val; return true; }
            if (f.type == giac::_CPLX) {
                gen re = *f._CPLXptr, im = *(f._CPLXptr + 1);
                if (re.type == giac::_DOUBLE_ && im.type == giac::_DOUBLE_) {
                    out = {re._DOUBLE_val, im._DOUBLE_val};
                    return true;
                }
            }
        } catch (...) {
        }
        return false;
    }

    bool isNumeric(const gen &g)
    {
        if (g.type == giac::_VECT || g.type == giac::_STRNG) return false;
        std::complex<double> c;
        return numericValue(g, c);
    }

    bool hasSommet(const gen &g, const char *name)
    {
        if (g.type == giac::_SYMB) {
            if (!strcmp(g._SYMBptr->sommet.ptr()->s, name)) return true;
            return hasSommet(g._SYMBptr->feuille, name);
        }
        if (g.type == giac::_VECT)
            for (auto &e : *g._VECTptr)
                if (hasSommet(e, name)) return true;
        return false;
    }

    bool hasComplexConst(const gen &g)
    {
        if (g.type == giac::_CPLX) return true;
        if (g.type == giac::_SYMB) return hasComplexConst(g._SYMBptr->feuille);
        if (g.type == giac::_VECT)
            for (auto &e : *g._VECTptr)
                if (hasComplexConst(e)) return true;
        return false;
    }

    QStringList varsOf(const gen &g)
    {
        static const QSet<QString> skip = {"pi", "infinity", "euler_gamma", "undef", "e", "i"};
        QStringList names;
        for (auto &e : giac::lidnt(g)) {
            QString n = P(e);
            if (!skip.contains(n) && !names.contains(n)) names << n;
        }
        static const QStringList pref = {"x", "y", "z", "t"};
        std::sort(names.begin(), names.end(), [](const QString &a, const QString &b) {
            int ia = pref.indexOf(a), ib = pref.indexOf(b);
            if (ia < 0) ia = 100;
            if (ib < 0) ib = 100;
            return ia != ib ? ia < ib : a < b;
        });
        return names;
    }

    // A product/power that still contains a sum, i.e. something expand() changes.
    bool hasSumFactor(const gen &g)
    {
        if (isS(g, "^")) return isS(args(g)[0], "+");
        if (isS(g, "*") || isS(g, "-") || isS(g, "inv") || isS(g, "/") || isS(g, "+"))
            for (auto &a : args(g))
                if (isS(a, "+") || hasSumFactor(a)) return true;
        return false;
    }

    // simplify() when it shortens the result; factored/expanded forms are
    // offered as alternatives only when they really differ.
    gen best(const gen &r, std::vector<std::pair<QString, gen>> *alts = nullptr)
    {
        if (r.type != giac::_SYMB) return r;
        gen b = r;
        try {
            gen sm = call("simplify", r);
            if (P(sm).size() < P(b).size()) b = sm;
        } catch (...) {
        }
        if (alts) {
            QSet<QString> seen = {P(b), P(r)};
            try {
                gen f = call("factor", b);
                if (hasSumFactor(f) && !seen.contains(P(f))) {
                    alts->push_back({QString::fromUtf8("Factorizada"), f});
                    seen.insert(P(f));
                }
            } catch (...) {
            }
            try {
                if (hasSumFactor(b)) {
                    gen e = call("expand", b);
                    if (isS(e, "+") && !seen.contains(P(e)) && P(e).size() < 400) alts->push_back({QString::fromUtf8("Desarrollada"), e});
                }
            } catch (...) {
            }
        }
        return b;
    }

    // Exact values that need no decimal companion: integers that fit on
    // screen and Gaussian integers.
    bool plainExact(const gen &g)
    {
        if (g.type == giac::_INT_) return g.subtype != giac::_INT_BOOLEAN;
        if (g.type == giac::_ZINT) return P(g).size() <= m_digits;
        if (g.type == giac::_CPLX) return plainExact(*g._CPLXptr) && plainExact(*(g._CPLXptr + 1));
        return false;
    }

    QString numText(const gen &a)
    {
        if (a.type == giac::_DOUBLE_) return fmtDouble(a._DOUBLE_val, m_digits);
        if (a.type == giac::_CPLX && a._CPLXptr->type == giac::_DOUBLE_ && (a._CPLXptr + 1)->type == giac::_DOUBLE_) {
            double re = a._CPLXptr->_DOUBLE_val, im = (a._CPLXptr + 1)->_DOUBLE_val;
            QString r = re != 0 ? fmtDouble(re, m_digits) : QString();
            QString i = fmtDouble(std::fabs(im), m_digits) + "*i";
            if (r.isEmpty()) return (im < 0 ? "-" : "") + i;
            return r + (im < 0 ? "-" : "+") + i;
        }
        return P(a);
    }

    // --------------------------------------------------- gen -> formula
    MPtr node(const gen &g) { int p; return conv(g, p); }
    MPtr wrap(const gen &g, int need)
    {
        int p;
        MPtr n = conv(g, p);
        return p < need ? M::paren(n) : n;
    }

    std::vector<gen> args(const gen &g)
    {
        const gen &f = g._SYMBptr->feuille;
        if (f.type == giac::_VECT) {
            static const QSet<QString> nary = {"+", "*", "and", "or", "=", "==", "<", ">", "<=", ">=", "!=", "^", "/", "-"};
            const bool isList = f.subtype == giac::_LIST__VECT || f.subtype == giac::_MATRIX__VECT || f.subtype == giac::_SET__VECT;
            if (f.subtype == giac::_SEQ__VECT || (!isList && nary.contains(QString::fromUtf8(sname(g)))))
                return std::vector<gen>(f._VECTptr->begin(), f._VECTptr->end());
        }
        return {f};
    }
    static const char *sname(const gen &g) { return g._SYMBptr->sommet.ptr()->s; }
    static bool isS(const gen &g, const char *n) { return g.type == giac::_SYMB && !strcmp(sname(g), n); }

    gen prodOf(const std::vector<gen> &v)
    {
        if (v.empty()) return gen(1);
        if (v.size() == 1) return v[0];
        vecteur w;
        for (auto &x : v) w.push_back(x);
        return giac::symbolic(giac::at_prod, gen(w, giac::_SEQ__VECT));
    }

    bool splitNeg(const gen &g, gen &out)
    {
        if (isNumType(g)) {
            if (g.type == giac::_FRAC && !isNumType(g._FRACptr->num)) return false;
            double d = dv(g);
            if (d < 0) { out = -g; return true; }
            return false;
        }
        if (g.type == giac::_CPLX) {
            gen re = *g._CPLXptr, im = *(g._CPLXptr + 1);
            if (giac::is_zero(re) && dv(im) < 0) { out = -g; return true; }
            return false;
        }
        if (isS(g, "-")) {
            auto a = args(g);
            if (a.size() == 1) { out = a[0]; return true; }
            return false;
        }
        if (isS(g, "*")) {
            auto a = args(g);
            gen f0;
            if (!a.empty() && splitNeg(a[0], f0)) {
                if (giac::is_one(f0)) a.erase(a.begin());
                else a[0] = f0;
                out = prodOf(a);
                return true;
            }
            return false;
        }
        if (isS(g, "/")) {
            auto a = args(g);
            gen n0;
            if (a.size() == 2 && splitNeg(a[0], n0)) {
                out = giac::symbolic(giac::at_division, gen(giac::makevecteur(n0, a[1]), giac::_SEQ__VECT));
                return true;
            }
        }
        return false;
    }

    MPtr numNode(const gen &g, int &prec)
    {
        prec = P_ATOM;
        QString s;
        switch (g.type) {
        case giac::_INT_:
            if (g.subtype == giac::_INT_BOOLEAN) return M::text(g.val ? "verdadero" : "falso");
            s = QString::number(g.val);
            break;
        case giac::_DOUBLE_: s = fmtDouble(g._DOUBLE_val, m_digits); break;
        default: s = P(g); break;
        }
        if (s.startsWith('-')) {
            prec = P_SUM;
            return M::row({unaryMinus(), numberNode(s.mid(1))});
        }
        return numberNode(s);
    }

    MPtr idNode(const QString &name)
    {
        if (greek().contains(name)) return M::var(greek()[name]);
        static const QRegularExpression idx("^([A-Za-z]+)_?([0-9]+)$");
        auto m = idx.match(name);
        if (m.hasMatch()) return M::sub(M::var(m.captured(1)), M::num(m.captured(2)));
        return M::var(name);
    }

    MPtr prodNode(const std::vector<gen> &v, int &prec)
    {
        if (v.empty()) { prec = P_ATOM; return M::num("1"); }
        if (v.size() == 1) return conv(v[0], prec);
        std::vector<MPtr> out;
        MPtr prev;
        for (auto &f : v) {
            MPtr n = wrap(f, P_PROD);
            if (prev) {
                if (startsWithNum(n)) out.push_back(M::op(QString::fromUtf8("·")));
                else if (prev->kind != MNode::Num || !startsWithVar(n)) out.push_back(M::space(2));
            }
            out.push_back(n);
            prev = n;
        }
        prec = P_PROD;
        return M::row(out);
    }

    MPtr fnCall(const QString &giacName, const std::vector<gen> &a)
    {
        QString name = displayNames().value(giacName, giacName);
        std::vector<MPtr> parts;
        for (auto &x : a) parts.push_back(node(x));
        return M::row({M::text(name), M::paren(joinNodes(parts, ","))});
    }

    // Bounds from "x > 1" style relations, used to chain a < x < b.
    bool bound(const gen &rel, gen &var, gen &val, bool &lower, bool &strict)
    {
        if (rel.type != giac::_SYMB) return false;
        QString s = sname(rel);
        auto a = args(rel);
        if (a.size() != 2) return false;
        bool lt = s == "<" || s == "<=", gt = s == ">" || s == ">=";
        if (!lt && !gt) return false;
        strict = s == "<" || s == ">";
        if (a[0].type == giac::_IDNT) { var = a[0]; val = a[1]; lower = gt; return true; }
        if (a[1].type == giac::_IDNT) { var = a[1]; val = a[0]; lower = lt; return true; }
        return false;
    }

    MPtr conv(const gen &g, int &prec)
    {
        prec = P_ATOM;
        if (giac::is_undef(g)) return M::text("indefinido");
        switch (g.type) {
        case giac::_INT_:
        case giac::_ZINT:
        case giac::_DOUBLE_:
        case giac::_REAL:
            return numNode(g, prec);
        case giac::_FRAC: {
            gen num = g._FRACptr->num, den = g._FRACptr->den;
            gen a;
            if (splitNeg(num, a)) {
                prec = P_SUM;
                return M::row({unaryMinus(), M::frac(node(a), node(den))});
            }
            prec = P_FRAC;
            return M::frac(node(num), node(den));
        }
        case giac::_CPLX: {
            gen re = *g._CPLXptr, im = *(g._CPLXptr + 1);
            std::vector<MPtr> parts;
            bool reZero = giac::is_zero(re);
            if (!reZero) parts.push_back(node(re));
            gen aim;
            bool neg = splitNeg(im, aim);
            if (!neg) aim = im;
            MPtr in = giac::is_one(aim) ? M::var("i") : M::row({wrap(aim, P_PROD), M::var("i")});
            if (neg) parts.push_back(reZero ? unaryMinus() : M::op(QString::fromUtf8("−")));
            else if (!reZero) parts.push_back(M::op("+"));
            parts.push_back(in);
            prec = (reZero && !neg) ? P_PROD : P_SUM;
            return M::row(parts);
        }
        case giac::_IDNT: return idNode(P(g));
        case giac::_STRNG: return M::text(QString::fromStdString(*g._STRNGptr));
        case giac::_FUNC: {
            QString n = QString::fromUtf8(g._FUNCptr->ptr()->s);
            return M::text(displayNames().value(n, n));
        }
        case giac::_VECT: {
            const vecteur &v = *g._VECTptr;
            bool mat = !v.empty() && g.subtype != giac::_SEQ__VECT;
            size_t cols = 0;
            for (auto &r : v) {
                if (r.type != giac::_VECT || r._VECTptr->empty()) { mat = false; break; }
                if (!cols) cols = r._VECTptr->size();
                else if (cols != r._VECTptr->size()) { mat = false; break; }
            }
            if (mat) {
                std::vector<MPtr> cells;
                for (auto &r : v)
                    for (auto &c : *r._VECTptr) cells.push_back(node(c));
                return M::paren(M::matrix(int(cols), cells), "()");
            }
            std::vector<MPtr> parts;
            for (auto &e : v) parts.push_back(node(e));
            if (g.subtype == giac::_SEQ__VECT) {
                prec = P_REL;
                return joinNodes(parts, ",");
            }
            return M::paren(joinNodes(parts, ","), g.subtype == giac::_SET__VECT ? "{}" : "[]");
        }
        case giac::_SYMB: return symb(g, prec);
        default: return M::text(P(g));
        }
    }

    MPtr symb(const gen &g, int &prec)
    {
        const QString s = QString::fromUtf8(sname(g));
        auto a = args(g);
        prec = P_ATOM;

        if (s == "+") {
            if (a.size() == 1) {
                prec = P_SUM;
                return M::row({unaryOp("+"), wrap(a[0], P_PROD)});
            }
            std::stable_partition(a.begin(), a.end(), [this](const gen &t) { return !P(t).contains("n_"); });
            std::vector<MPtr> parts;
            for (size_t i = 0; i < a.size(); ++i) {
                gen abs;
                bool neg = splitNeg(a[i], abs);
                if (!neg) abs = a[i];
                if (i == 0) {
                    if (neg) parts.push_back(unaryMinus());
                } else {
                    parts.push_back(M::op(neg ? QString::fromUtf8("−") : "+"));
                }
                parts.push_back(wrap(abs, (neg || i > 0) ? P_PROD : P_SUM));
            }
            prec = P_SUM;
            return M::row(parts);
        }
        if (s == "-") {
            prec = P_SUM;
            if (a.size() == 1) return M::row({unaryMinus(), wrap(a[0], P_PROD)});
            return M::row({wrap(a[0], P_SUM), M::op(QString::fromUtf8("−")), wrap(a[1], P_PROD)});
        }
        if (s == "*") {
            gen abs;
            if (splitNeg(g, abs)) {
                prec = P_SUM;
                return M::row({unaryMinus(), wrap(abs, P_PROD)});
            }
            std::vector<gen> num, den;
            bool order = false;
            std::function<void(const gen &)> add = [&](const gen &f) {
                if (isS(f, "*")) {
                    for (auto &x : args(f)) add(x);
                } else if (isS(f, "inv")) {
                    den.push_back(args(f)[0]);
                } else if (isS(f, "^") && isNumType(args(f)[1]) && dv(args(f)[1]) < 0) {
                    auto pa = args(f);
                    gen e = -pa[1];
                    den.push_back(giac::is_one(e) ? pa[0] : giac::symbolic(giac::at_pow, gen(giac::makevecteur(pa[0], e), giac::_SEQ__VECT)));
                } else if (f.type == giac::_FRAC && isNumType(f._FRACptr->num)) {
                    if (!giac::is_one(f._FRACptr->num)) num.push_back(f._FRACptr->num);
                    den.push_back(f._FRACptr->den);
                } else if (isS(f, "order_size")) {
                    order = true;
                } else {
                    num.push_back(f);
                }
            };
            for (auto &f : a) add(f);
            int pn, pd;
            if (order) {
                MPtr inner = prodNode(num, pn);
                return M::row({M::text("O"), M::paren(inner)});
            }
            MPtr nn = prodNode(num, pn);
            if (den.empty()) { prec = pn; return nn; }
            prec = P_FRAC;
            return M::frac(nn, prodNode(den, pd));
        }
        if (s == "/") {
            prec = P_FRAC;
            return M::frac(node(a[0]), node(a[1]));
        }
        if (s == "inv") {
            prec = P_FRAC;
            return M::frac(M::num("1"), node(a[0]));
        }
        if (s == "^" && a.size() == 2) {
            const gen &b = a[0], &e = a[1];
            if (e.type == giac::_FRAC && giac::is_one(e._FRACptr->num)) {
                gen d = e._FRACptr->den;
                if (d.type == giac::_INT_ && d.val == 2) return M::sqrt(node(b));
                return M::sqrt(node(b), node(d));
            }
            if (isNumType(e) && dv(e) < 0) {
                prec = P_FRAC;
                gen pe = -e;
                gen p = giac::is_one(pe) ? b : giac::symbolic(giac::at_pow, gen(giac::makevecteur(b, pe), giac::_SEQ__VECT));
                return M::frac(M::num("1"), node(p));
            }
            static const QSet<QString> powFns = {"sin", "cos", "tan", "cot", "sec", "csc", "sinh", "cosh", "tanh", "ln", "log10"};
            if (b.type == giac::_SYMB && powFns.contains(sname(b)) && e.type == giac::_INT_ && e.val > 0) {
                QString fn = displayNames().value(sname(b), sname(b));
                prec = P_POW;
                return M::row({M::pow(M::text(fn), node(e)), M::paren(node(args(b)[0]))});
            }
            prec = P_POW;
            return M::pow(wrap(b, P_ATOM), node(e));
        }
        if (s == "exp") {
            if (giac::is_one(a[0])) return M::var("e");
            prec = P_POW;
            return M::pow(M::var("e"), node(a[0]));
        }
        if (s == "sqrt") return M::sqrt(node(a[0]));
        if (s == "surd" && a.size() == 2) return M::sqrt(node(a[0]), node(a[1]));
        if (s == "abs") return M::paren(node(a[0]), "||");
        if (s == "conj") return M::conj(node(a[0]));
        if (s == "floor") return M::paren(node(a[0]), QString::fromUtf8("⌊⌋"));
        if (s == "ceil") return M::paren(node(a[0]), QString::fromUtf8("⌈⌉"));
        if (s == "factorial") return M::row({wrap(a[0], P_ATOM), M::text("!")});
        if (s == "comb" && a.size() == 2) return M::paren(M::matrix(1, {node(a[0]), node(a[1])}));
        if (s == "irem" && a.size() == 2) {
            prec = P_SUM;
            return M::row({wrap(a[0], P_PROD), M::op("mod"), wrap(a[1], P_PROD)});
        }
        if (s == "logb" && a.size() == 2)
            return M::row({M::sub(M::text("log"), node(a[1])), M::paren(node(a[0]))});
        static const QHash<QString, QString> rels = {
            {"=", "="}, {"==", "="}, {"<", "<"}, {">", ">"}, {"<=", QString::fromUtf8("≤")},
            {">=", QString::fromUtf8("≥")}, {"!=", QString::fromUtf8("≠")}};
        if (rels.contains(s) && a.size() == 2) {
            prec = P_REL;
            return M::row({node(a[0]), M::op(rels[s]), node(a[1])});
        }
        if (s == "and" || s == "or") {
            prec = P_REL;
            if (s == "and" && a.size() == 2) {
                gen v1, c1, v2, c2;
                bool lo1, lo2, st1, st2;
                if (bound(a[0], v1, c1, lo1, st1) && bound(a[1], v2, c2, lo2, st2) && v1 == v2 && lo1 != lo2) {
                    if (!lo1) std::swap(c1, c2), std::swap(st1, st2);
                    QString o1 = st1 ? "<" : QString::fromUtf8("≤"), o2 = st2 ? "<" : QString::fromUtf8("≤");
                    return M::row({node(c1), M::op(o1), node(v1), M::op(o2), node(c2)});
                }
            }
            std::vector<MPtr> parts;
            for (size_t i = 0; i < a.size(); ++i) {
                if (i) parts.push_back(M::op(s == "and" ? QString::fromUtf8("∧") : QString::fromUtf8("∨")));
                parts.push_back(node(a[i]));
            }
            return M::row(parts);
        }
        if (s == "not") return M::row({M::text(QString::fromUtf8("¬")), wrap(a[0], P_ATOM)});
        if ((s == "integrate" || s == "int") && a.size() >= 2) {
            MPtr body = M::row({wrap(a[0], P_SUM + 1), M::space(3), M::text("d"), node(a[1])});
            if (a.size() >= 4) return M::bigop(QString::fromUtf8("∫"), body, node(a[2]), node(a[3]));
            return M::bigop(QString::fromUtf8("∫"), body, nullptr, nullptr);
        }
        if ((s == "diff" || s == "derive") && a.size() >= 2)
            return M::row({M::frac(M::text("d"), M::row({M::text("d"), node(a[1])})), M::paren(node(a[0]))});
        if (s == "sum" && a.size() == 4)
            return M::bigop(QString::fromUtf8("∑"), wrap(a[0], P_PROD), M::row({node(a[1]), M::op("="), node(a[2])}), node(a[3]));
        if (s == "limit" && a.size() >= 3)
            return M::row({M::under(M::text(QString::fromUtf8("lím")), M::row({node(a[1]), M::op(QString::fromUtf8("→")), node(a[2])})), M::space(3), wrap(a[0], P_PROD)});
        if (s == "sto" && a.size() == 2) {
            prec = P_REL;
            return M::row({node(a[1]), M::op(":="), node(a[0])});
        }
        if (s == "rootof") {
            try { return node(giac::evalf(g, 1, &m_ctx)); } catch (...) {}
        }
        if (s == "of" && a.size() == 2) return M::row({node(a[0]), M::paren(node(a[1]))});
        if (s == "program" || s == "when" || s == "piecewise") return M::text(P(g));
        return fnCall(s, a);
    }

    // -------------------------------------------------------- compiling
    bool compileRec(const gen &g, const QStringList &vars, Program &p, int &depth, int &maxDepth, QString &err)
    {
        auto push = [&](Program::Op op, int a = 0, double pp = 0, double q = 0) {
            p.code.push_back({op, a, pp, q});
        };
        auto grow = [&](int d) { depth += d; maxDepth = std::max(maxDepth, depth); };
        auto constant = [&](std::complex<double> c) {
            p.consts.push_back(c);
            push(Program::Const, int(p.consts.size()) - 1);
            grow(1);
        };
        std::complex<double> c;
        if (g.type != giac::_SYMB && g.type != giac::_IDNT && g.type != giac::_VECT && numericValue(g, c)) {
            constant(c);
            return true;
        }
        if (g.type == giac::_IDNT) {
            QString n = P(g);
            int idx = vars.indexOf(n);
            if (idx >= 0) {
                push(Program::Var, idx);
                grow(1);
                return true;
            }
            if (n == "infinity") { constant(INFINITY); return true; }
            if (numericValue(g, c)) { constant(c); return true; }
            err = QString::fromUtf8("Variable sin valor: %1").arg(n);
            return false;
        }
        if (g.type != giac::_SYMB) {
            err = QString::fromUtf8("No se puede dibujar: %1").arg(P(g));
            return false;
        }
        if (giac::lidnt(g).empty() && numericValue(g, c)) {
            constant(c);
            return true;
        }
        QString s = sname(g);
        auto a = args(g);
        auto all = [&]() {
            for (auto &x : a)
                if (!compileRec(x, vars, p, depth, maxDepth, err)) return false;
            return true;
        };
        static const QHash<QString, Program::Op> unary = {
            {"sin", Program::Sin}, {"cos", Program::Cos}, {"tan", Program::Tan},
            {"asin", Program::Asin}, {"acos", Program::Acos}, {"atan", Program::Atan},
            {"sinh", Program::Sinh}, {"cosh", Program::Cosh}, {"tanh", Program::Tanh},
            {"asinh", Program::Asinh}, {"acosh", Program::Acosh}, {"atanh", Program::Atanh},
            {"sec", Program::Sec}, {"csc", Program::Csc}, {"cot", Program::Cot},
            {"exp", Program::Exp}, {"ln", Program::Ln}, {"log", Program::Ln}, {"log10", Program::Log10},
            {"sqrt", Program::Sqrt}, {"abs", Program::Abs}, {"sign", Program::Sign},
            {"floor", Program::Floor}, {"ceil", Program::Ceil}, {"round", Program::Round},
            {"re", Program::Re}, {"im", Program::Im}, {"arg", Program::Arg}, {"conj", Program::Conj},
            {"erf", Program::Erf}, {"Gamma", Program::Gamma}, {"Heaviside", Program::Heaviside},
        };
        static const QHash<QString, Program::Op> binary = {
            {"min", Program::Min}, {"max", Program::Max}, {"atan2", Program::Atan2},
            {"<", Program::Lt}, {"<=", Program::Le}, {">", Program::Gt}, {">=", Program::Ge},
            {"=", Program::Eq}, {"==", Program::Eq}, {"!=", Program::Ne},
        };
        if (s == "+" || s == "*" || s == "and" || s == "or") {
            if (!all()) return false;
            Program::Op op = s == "+" ? Program::Add : s == "*" ? Program::Mul : s == "and" ? Program::And : Program::Or;
            for (size_t i = 1; i < a.size(); ++i) push(op), grow(-1);
            return true;
        }
        if (s == "-") {
            if (!all()) return false;
            if (a.size() == 1) push(Program::Neg);
            else push(Program::Sub), grow(-1);
            return true;
        }
        if (s == "/") {
            if (!all()) return false;
            push(Program::Div), grow(-1);
            return true;
        }
        if (s == "inv") {
            constant(1);
            if (!all()) return false;
            push(Program::Div), grow(-1);
            return true;
        }
        if (s == "^" && a.size() == 2) {
            const gen &e = a[1];
            if (!compileRec(a[0], vars, p, depth, maxDepth, err)) return false;
            if (e.type == giac::_INT_ && std::abs(e.val) < 1000) {
                push(Program::PowInt, e.val);
                return true;
            }
            if (e.type == giac::_FRAC && e._FRACptr->num.type == giac::_INT_ && e._FRACptr->den.type == giac::_INT_ &&
                e._FRACptr->den.val % 2 != 0) {
                push(Program::RootOdd, 0, e._FRACptr->num.val, e._FRACptr->den.val);
                return true;
            }
            if (!compileRec(e, vars, p, depth, maxDepth, err)) return false;
            push(Program::Pow), grow(-1);
            return true;
        }
        if (s == "surd" && a.size() == 2 && a[1].type == giac::_INT_) {
            if (!compileRec(a[0], vars, p, depth, maxDepth, err)) return false;
            if (a[1].val % 2) push(Program::RootOdd, 0, 1, a[1].val);
            else { constant(1.0 / a[1].val); push(Program::Pow); grow(-1); }
            return true;
        }
        if (s == "logb" && a.size() == 2) {
            if (!compileRec(a[0], vars, p, depth, maxDepth, err)) return false;
            push(Program::Ln);
            if (!compileRec(a[1], vars, p, depth, maxDepth, err)) return false;
            push(Program::Ln);
            push(Program::Div), grow(-1);
            return true;
        }
        if (s == "factorial" && a.size() == 1) {
            if (!all()) return false;
            constant(1);
            push(Program::Add), grow(-1);
            push(Program::Gamma);
            return true;
        }
        if ((s == "when" || s == "ifte") && a.size() == 3) {
            if (!all()) return false;
            push(Program::Ifte), grow(-2);
            return true;
        }
        if (s == "piecewise" && a.size() >= 2) {
            // piecewise(c1, v1, c2, v2, ..., [default])
            std::function<bool(size_t)> pw = [&](size_t k) -> bool {
                if (k + 1 >= a.size()) {
                    if (k < a.size()) return compileRec(a[k], vars, p, depth, maxDepth, err);
                    constant(NAN);
                    return true;
                }
                if (!compileRec(a[k], vars, p, depth, maxDepth, err)) return false;
                if (!compileRec(a[k + 1], vars, p, depth, maxDepth, err)) return false;
                if (!pw(k + 2)) return false;
                push(Program::Ifte), grow(-2);
                return true;
            };
            return pw(0);
        }
        if (unary.contains(s) && a.size() == 1) {
            if (!all()) return false;
            push(unary[s]);
            return true;
        }
        if (binary.contains(s) && a.size() == 2) {
            if (!all()) return false;
            push(binary[s]), grow(-1);
            return true;
        }
        err = QString::fromUtf8("No sé dibujar la función «%1».").arg(displayNames().value(s, s));
        return false;
    }

    Program compile(const gen &g, const QStringList &vars, QString *errOut = nullptr)
    {
        Program p;
        p.nvars = vars.size();
        int depth = 0, maxDepth = 0;
        QString err;
        p.valid = compileRec(g, vars, p, depth, maxDepth, err) && maxDepth < 90;
        if (!p.valid && err.isEmpty()) err = QString::fromUtf8("Expresión demasiado anidada para dibujar.");
        if (!p.valid) {
            p.code.clear();
            if (errOut) *errOut = err;
        }
        return p;
    }

    Program compileOrThrow(const gen &g, const QStringList &vars)
    {
        QString err;
        Program p = compile(g, vars, &err);
        if (!p.valid) throw CasError(err);
        return p;
    }

    // -------------------------------------------------------- items
    ResultItem item(const QString &caption, MPtr f, const gen &g)
    {
        ResultItem it;
        it.caption = caption;
        it.formula = std::move(f);
        it.text = P(g);
        it.latex = tex(g);
        return it;
    }

    MPtr approxNode(const gen &g, QString *text = nullptr)
    {
        gen a = giac::evalf(g, 1, &m_ctx);
        if (m_digits > 15) {
            try { a = run(QString("evalf(%1,%2)").arg(P(g)).arg(m_digits)); } catch (...) {}
        }
        if (text) *text = numText(a);
        return node(a);
    }

    // ------------------------------------------------------- previews
    MPtr userNode(const QString &raw)
    {
        RelSplit rs = splitRel(raw);
        std::vector<MPtr> parts;
        for (int i = 0; i < rs.parts.size(); ++i) {
            if (i) parts.push_back(M::op(relSymbol(rs.ops[i - 1])));
            if (rs.parts[i].isEmpty()) continue;
            parts.push_back(node(parse(prep(rs.parts[i]))));
        }
        return M::row(parts);
    }

    void preview(const Request &rq, Response &r)
    {
        if (rq.text.trimmed().isEmpty()) return;
        try {
            r.preview = userNode(rq.text);
        } catch (...) {
            r.ok = false;
        }
    }

    // ------------------------------------------------------- evaluate
    void evaluate(const Request &rq, Response &r)
    {
        const QString src = rq.text.trimmed();
        if (src.isEmpty()) return;

        static const QRegularExpression defRe(
            "^\\s*([A-Za-z_]\\w*)\\s*(?:\\(\\s*([A-Za-z_]\\w*(?:\\s*,\\s*[A-Za-z_]\\w*)*)\\s*\\))?\\s*(:=|=)(?!=)\\s*(.+)$");
        auto m = defRe.match(src);
        if (m.hasMatch()) {
            QString name = m.captured(1), params = m.captured(2), op = m.captured(3), body = m.captured(4);
            static const QSet<QString> reserved = {"x", "y", "z", "t", "e", "i", "pi", "ans", "ans_"};
            QRegularExpression self("\\b" + QRegularExpression::escape(name) + "\\b");
            bool reservedName = reserved.contains(name) || aliases().contains(name) ||
                                (isFunction(name) && !m_userFuncs.contains(name));
            bool isDef = !reservedName && (op == ":=" || !params.isEmpty() || !self.match(body).hasMatch());
            if (!splitRel(body).ops.isEmpty()) isDef = false;
            if (isDef) {
                defineUser(name, params, body, rq.deg, r);
                return;
            }
        }

        RelSplit rs = splitRel(src);
        if (!rs.ops.isEmpty()) {
            solveLines({src}, QString(), false, r, false);
            r.summary = r.items.empty() ? QString() : r.items.front().text;
            return;
        }

        gen input = parse(prep(src, rq.deg));
        gen res = ev(input);
        giac::sto(res, giac::identificateur("ans_"), &m_ctx);
        MPtr inNode = node(input);

        if (res.type == giac::_INT_ && res.subtype == giac::_INT_BOOLEAN) {
            r.items.push_back(item({}, M::row({inNode, M::op(QString::fromUtf8("⟹")), M::text(res.val ? "Verdadero" : "Falso")}), res));
            r.summary = res.val ? "Verdadero" : "Falso";
            return;
        }

        if (isNumeric(res)) {
            if (res.type == giac::_SYMB) res = best(res);
            const bool sameAsInput = P(input) == P(res);
            QString approxText;
            MPtr ap = approxNode(res, &approxText);
            const bool exactIsFloat = res.type == giac::_DOUBLE_ || res.type == giac::_REAL ||
                                      (res.type == giac::_CPLX && (res._CPLXptr->type == giac::_DOUBLE_ || res._CPLXptr->type == giac::_REAL));
            const bool showApprox = !exactIsFloat && !plainExact(res) && approxText != P(res);
            std::vector<MPtr> row;
            if (!sameAsInput) row = {inNode, M::op("=")};
            row.push_back(node(res));
            if (showApprox) row.insert(row.end(), {M::op(QString::fromUtf8("≈")), ap});
            ResultItem main = item({}, M::row(row), res);
            if (exactIsFloat) main.text = numText(res);
            r.items.push_back(main);
            r.summary = showApprox ? approxText : main.text;

            std::complex<double> c;
            numericValue(res, c);
            if (std::abs(c.imag()) > 1e-12 * std::max(1.0, std::abs(c))) complexExtras(res, rq.deg, r);
            else if ((res.type == giac::_INT_ || res.type == giac::_ZINT) && QRegularExpression("^\\s*\\d+\\s*$").match(src).hasMatch())
                integerExtras(res, r);
            return;
        }

        std::vector<std::pair<QString, gen>> alts;
        gen b = best(res, &alts);
        r.items.clear();
        std::vector<MPtr> row;
        if (P(input) != P(b)) row = {inNode, M::op("=")};
        row.push_back(node(b));
        r.items.push_back(item({}, M::row(row), b));
        for (auto &a : alts) r.items.push_back(item(a.first, node(a.second), a.second));
        r.summary = P(b);
    }

    void complexExtras(const gen &z, bool deg, Response &r)
    {
        auto pick = [&](const gen &g) -> gen {
            return P(g).size() > 40 ? giac::evalf(g, 1, &m_ctx) : g;
        };
        gen mod = pick(call("simplify", call("abs", z)));
        giac::angle_radian(true, &m_ctx);
        gen argRad = pick(call("simplify", call("arg", z)));
        gen argShown = argRad;
        if (deg) argShown = pick(call("simplify", run("(" + P(argRad) + ")*180/pi")));
        gen re = pick(call("simplify", call("re", z))), im = pick(call("simplify", call("im", z)));

        MPtr modN = node(mod), argN = node(argShown);
        if (deg) argN = M::row({argN, M::text(QString::fromUtf8("°"))});
        MPtr bin = node(run("(" + P(re) + ")+(" + P(im) + ")*i"));
        r.items.push_back(item(QString::fromUtf8("Forma binómica"), bin, run("(" + P(re) + ")+(" + P(im) + ")*i")));
        ResultItem polar;
        polar.caption = QString::fromUtf8("Forma polar  (módulo y argumento)");
        polar.formula = M::sub(wrap(mod, P_ATOM), argN);
        polar.text = P(mod) + "_" + P(argShown) + (deg ? QString::fromUtf8("°") : QString());
        polar.latex = tex(mod) + "_{" + tex(argShown) + (deg ? "^{\\circ}" : "") + "}";
        r.items.push_back(polar);
        ResultItem trig;
        trig.caption = QString::fromUtf8("Forma trigonométrica");
        MPtr argP = M::paren(argN);
        trig.formula = M::row({wrap(mod, P_PROD), M::paren(M::row({M::text("cos"), argP, M::op("+"), M::var("i"), M::space(2), M::text("sen"), argP}))});
        trig.text = P(mod) + "*(cos(" + P(argShown) + ")+i*sin(" + P(argShown) + "))";
        r.items.push_back(trig);
        ResultItem ex;
        ex.caption = QString::fromUtf8("Forma exponencial");
        int pa;
        MPtr argExp = conv(argRad, pa);
        ex.formula = M::row({wrap(mod, P_PROD), M::space(2), M::pow(M::var("e"), M::row({M::var("i"), pa < P_PROD ? M::paren(argExp) : argExp}))});
        ex.text = P(mod) + "*exp(i*(" + P(argRad) + "))";
        r.items.push_back(ex);
        r.items.push_back(item(QString::fromUtf8("Conjugado"), M::row({M::conj(M::var("z")), M::op("="), node(call("conj", z))}), call("conj", z)));
    }

    void integerExtras(const gen &n, Response &r)
    {
        QString s = P(n);
        if (s.startsWith('-')) s.remove(0, 1);
        if (s.size() > 30 || s == "0" || s == "1") return;
        gen prime = call("isprime", n);
        if (prime.type == giac::_INT_ && prime.val) {
            ResultItem it;
            it.caption = QString::fromUtf8("Número primo");
            it.formula = M::text(QString::fromUtf8("%1 es primo").arg(s));
            it.text = s;
            r.items.push_back(it);
            return;
        }
        gen f = call("ifactor", n);
        r.items.push_back(item(QString::fromUtf8("Factorización en primos"), node(f), f));
    }

    void defineUser(const QString &name, const QString &params, const QString &body, bool deg, Response &r)
    {
        QString lhs = params.isEmpty() ? name : name + "(" + params.simplified().replace(" ", "") + ")";
        QString src = lhs + ":=" + prep(body, deg);
        if (!params.isEmpty()) m_userFuncs.insert(name);
        gen v;
        try {
            v = run(src);
        } catch (...) {
            if (!params.isEmpty()) m_userFuncs.remove(name);
            throw;
        }
        m_funcCache.remove(name);
        r.definition = src;
        r.definedName = lhs;
        gen bodyG = parse(prep(body, deg));
        MPtr left = params.isEmpty() ? idNode(name) : M::row({M::var(name), M::paren(node(parse(params)))});
        std::vector<MPtr> row = {left, M::op(":="), node(bodyG)};
        if (params.isEmpty() && P(v) != P(bodyG)) row.insert(row.end(), {M::op("="), node(v)});
        ResultItem it;
        it.caption = params.isEmpty() ? QString::fromUtf8("Variable guardada") : QString::fromUtf8("Función guardada");
        it.formula = M::row(row);
        it.text = src;
        it.latex = tex(bodyG);
        r.items.push_back(it);
        r.summary = lhs + " := " + P(params.isEmpty() ? v : bodyG);
    }

    // ---------------------------------------------------------- solve
    struct Rel {
        gen lhs, rhs, expr;  // expr = lhs - rhs
        QString op;          // = < <= > >= !=
    };

    std::vector<Rel> parseRelations(const QStringList &lines)
    {
        std::vector<Rel> rels;
        for (QString line : lines) {
            line = line.trimmed();
            if (line.isEmpty() || line.startsWith('#')) continue;
            RelSplit rs = splitRel(line);
            if (rs.ops.contains(":=")) throw CasError(QString::fromUtf8("Usa «=» en las ecuaciones (no «:=»)."));
            if (rs.ops.isEmpty()) {
                gen e = user(line);
                rels.push_back({e, gen(0), e, "="});
                continue;
            }
            for (int i = 0; i < rs.ops.size(); ++i) {
                if (rs.parts[i].isEmpty() || rs.parts[i + 1].isEmpty())
                    throw CasError(QString::fromUtf8("Falta un miembro en «%1».").arg(line));
                gen l = user(rs.parts[i]), rr = user(rs.parts[i + 1]);
                rels.push_back({l, rr, ev(giac::symbolic(giac::at_plus, gen(giac::makevecteur(l, -rr), giac::_SEQ__VECT))), rs.ops[i]});
            }
        }
        if (rels.empty()) throw CasError(QString::fromUtf8("Escribe al menos una ecuación."));
        return rels;
    }

    QString relSrc(const Rel &r) { return "(" + P(r.lhs) + ")" + r.op + "(" + P(r.rhs) + ")"; }
    MPtr relNode(const Rel &r) { return M::row({node(r.lhs), M::op(relSymbol(r.op)), node(r.rhs)}); }

    void solveRequest(const Request &rq, Response &r)
    {
        solveLines(rq.lines, rq.params.value("vars").toString(), rq.params.value("complex").toBool(), r, true);
    }

    MPtr assignRow(const QStringList &vars, const vecteur &vals)
    {
        std::vector<MPtr> parts;
        for (int i = 0; i < vars.size() && i < int(vals.size()); ++i) {
            if (i) parts.insert(parts.end(), {M::text(","), M::space(8)});
            parts.insert(parts.end(), {idNode(vars[i]), M::op("="), node(vals[i])});
        }
        return M::row(parts);
    }

    QString assignText(const QStringList &vars, const vecteur &vals)
    {
        QStringList s;
        for (int i = 0; i < vars.size() && i < int(vals.size()); ++i) s << vars[i] + " = " + P(vals[i]);
        return s.join(", ");
    }

    gen evalfIfRootof(const gen &g)
    {
        return hasSommet(g, "rootof") ? giac::evalf(g, 1, &m_ctx) : g;
    }

    void solveLines(const QStringList &lines, const QString &varsText, bool complexDomain, Response &r, bool withPlot)
    {
        std::vector<Rel> rels = parseRelations(lines);
        QStringList vars;
        if (!varsText.trimmed().isEmpty()) {
            for (QString v : varsText.split(QRegularExpression("[,;\\s]+"), Qt::SkipEmptyParts)) vars << v;
        } else {
            vecteur all;
            for (auto &x : rels) all.push_back(x.expr);
            vars = varsOf(gen(all, giac::_SEQ__VECT));
        }
        std::vector<Rel> eqs, ineqs;
        for (auto &x : rels) {
            if (x.expr.type == giac::_INT_ && x.expr.subtype == giac::_INT_BOOLEAN) continue;
            (x.op == "=" ? eqs : ineqs).push_back(x);
        }
        if (vars.isEmpty()) {
            bool allTrue = true;
            for (auto &x : rels) {
                gen v = run("evalb(" + relSrc(x) + ")");
                if (!(v.type == giac::_INT_ && v.val)) allTrue = false;
            }
            ResultItem it;
            it.formula = M::text(allTrue ? QString::fromUtf8("Se cumple (es cierto)") : QString::fromUtf8("No se cumple (es falso)"));
            it.text = allTrue ? "true" : "false";
            r.items.push_back(it);
            r.summary = it.text;
            return;
        }
        if (!ineqs.empty() && complexDomain)
            throw CasError(QString::fromUtf8("Las inecuaciones solo tienen sentido en los reales."));

        auto plotSpec = std::make_shared<PlotSpec>();
        std::vector<QPointF> marks;

        if (ineqs.empty() && vars.size() == 1) {
            solveOneVar(eqs, vars[0], complexDomain, r, marks);
        } else if (ineqs.empty()) {
            solveSystem(eqs, vars, complexDomain, r, marks);
        } else if (vars.size() == 1) {
            solveIneq1(rels, vars[0], r, *plotSpec);
        } else if (vars.size() == 2) {
            solveIneq2(rels, vars, r, marks);
        } else {
            throw CasError(QString::fromUtf8("Con inecuaciones solo sé resolver hasta dos incógnitas."));
        }
        if (!withPlot || complexDomain || vars.size() > 2) return;

        // ---- plot of the problem
        try {
            PlotSpec &ps = *plotSpec;
            if (vars.size() == 1) {
                ps.xname = vars[0];
                ps.yname = "y";
                for (auto &x : rels) {
                    Series s;
                    s.kind = Series::Func;
                    s.p.push_back(compileOrThrow(x.expr, {vars[0]}));
                    s.label = M::row({M::var("y"), M::op("="), node(x.expr)});
                    ps.series.push_back(s);
                }
            } else {
                ps.xname = vars[0];
                ps.yname = vars[1];
                ps.equalAspect = true;
                for (auto &x : eqs) {
                    Series s;
                    s.kind = Series::Implicit;
                    s.p.push_back(compileOrThrow(x.expr, vars));
                    s.label = relNode(x);
                    ps.series.push_back(s);
                }
                if (!ineqs.empty()) {
                    Series s;
                    s.kind = Series::Region;
                    std::vector<MPtr> lbl;
                    for (auto &x : ineqs) {
                        s.p.push_back(compileOrThrow(x.expr, vars));
                        s.rel.push_back(relCode(x.op));
                        if (!lbl.empty()) lbl.push_back(M::op(QString::fromUtf8("∧")));
                        lbl.push_back(relNode(x));
                    }
                    s.label = M::row(lbl);
                    ps.series.push_back(s);
                }
            }
            if (!marks.empty()) {
                Series s;
                s.kind = Series::Points;
                s.pts = marks;
                ps.series.push_back(s);
            }
            fitRange(ps, marks);
            r.plot = plotSpec;
        } catch (...) {
        }
    }

    static int relCode(const QString &op)
    {
        if (op == "<") return Series::Lt;
        if (op == "<=") return Series::Le;
        if (op == ">") return Series::Gt;
        if (op == ">=") return Series::Ge;
        return Series::Ne;
    }

    static void fitRange(PlotSpec &ps, const std::vector<QPointF> &marks)
    {
        double lo = -10, hi = 10;
        if (!marks.empty()) {
            double mn = INFINITY, mx = -INFINITY;
            for (auto &p : marks) {
                if (!std::isfinite(p.x())) continue;
                mn = std::min(mn, p.x());
                mx = std::max(mx, p.x());
                if (ps.series.size() && ps.equalAspect && std::isfinite(p.y())) {
                    mn = std::min(mn, p.y());
                    mx = std::max(mx, p.y());
                }
            }
            if (std::isfinite(mn)) {
                double span = std::max(mx - mn, 2.0);
                lo = mn - span * 0.6;
                hi = mx + span * 0.6;
            }
        }
        for (auto &s : ps.series) {
            if (s.kind != Series::XBand) continue;
            for (auto &iv : s.intervals) {
                if (std::isfinite(iv.first)) lo = std::min(lo, iv.first - 2), hi = std::max(hi, iv.first + 2);
                if (std::isfinite(iv.second)) lo = std::min(lo, iv.second - 2), hi = std::max(hi, iv.second + 2);
            }
        }
        ps.xmin = lo;
        ps.xmax = hi;
    }

    vecteur eqList(const std::vector<Rel> &eqs)
    {
        vecteur v;
        for (auto &e : eqs) v.push_back(giac::symbolic(giac::at_equal, gen(giac::makevecteur(e.lhs, e.rhs), giac::_SEQ__VECT)));
        return v;
    }
    QString listSrc(const vecteur &v)
    {
        QStringList s;
        for (auto &e : v) s << P(e);
        return "[" + s.join(",") + "]";
    }

    void solveOneVar(const std::vector<Rel> &eqs, const QString &v, bool complexDomain, Response &r, std::vector<QPointF> &marks)
    {
        if (eqs.size() == 1) {
            gen simp = call("simplify", eqs[0].expr);
            if (giac::is_zero(simp)) {
                ResultItem it;
                it.caption = QString::fromUtf8("Identidad");
                it.formula = M::text(QString::fromUtf8("Se cumple para todo %1").arg(v));
                it.text = "all";
                r.items.push_back(it);
                r.summary = it.formula->text;
                return;
            }
        }
        QString eqs_ = listSrc(eqList(eqs));
        gen sols;
        bool symbolicOk = true;
        giac::all_trig_sol(true, &m_ctx);
        try {
            sols = run(QString("%1(%2,%3)").arg(complexDomain ? "cSolve" : "solve", eqs_, v));
        } catch (...) {
            symbolicOk = false;
        }
        giac::all_trig_sol(false, &m_ctx);
        if (symbolicOk && sols.type != giac::_VECT) symbolicOk = false;
        if (symbolicOk && hasSommet(sols, "solve")) symbolicOk = false;

        if (!symbolicOk) {
            if (eqs.size() != 1 || complexDomain) throw CasError(QString::fromUtf8("No he encontrado una solución exacta."));
            numericRoots(eqs[0].expr, v, r, marks);
            return;
        }
        vecteur list = *sols._VECTptr;
        if (list.empty()) {
            if (!complexDomain) {
                gen cs;
                try { cs = run(QString("cSolve(%1,%2)").arg(eqs_, v)); } catch (...) {}
                if (cs.type == giac::_VECT && !cs._VECTptr->empty()) {
                    ResultItem it;
                    it.caption = QString::fromUtf8("Sin soluciones reales · soluciones complejas:");
                    it.formula = M::text(QString::fromUtf8("No tiene solución en ℝ"));
                    r.items.push_back(it);
                    addSolutions(*cs._VECTptr, v, r, marks, false);
                    r.summary = QString::fromUtf8("Sin solución real");
                    return;
                }
            }
            ResultItem it;
            it.formula = M::text(QString::fromUtf8("Sin solución"));
            it.text = "[]";
            r.items.push_back(it);
            r.summary = QString::fromUtf8("Sin solución");
            return;
        }
        addSolutions(list, v, r, marks, true);
    }

    void addSolutions(const vecteur &list, const QString &v, Response &r, std::vector<QPointF> &marks, bool mark)
    {
        QStringList summary;
        bool periodic = false;
        for (auto s0 : list) {
            gen s = evalfIfRootof(s0);
            std::vector<MPtr> row = {idNode(v), M::op("="), node(s)};
            QString approx;
            if (isNumeric(s) && !plainExact(s) && !(s.type == giac::_DOUBLE_ || s.type == giac::_REAL)) {
                MPtr a = approxNode(s, &approx);
                if (approx != P(s)) row.insert(row.end(), {M::op(QString::fromUtf8("≈")), a});
                else approx.clear();
            }
            if (P(s).contains("n_")) periodic = true;
            ResultItem it = item({}, M::row(row), s);
            it.text = v + " = " + P(s);
            r.items.push_back(it);
            summary << it.text;
            std::complex<double> c;
            if (mark && numericValue(s, c) && std::abs(c.imag()) < 1e-12) marks.push_back({c.real(), 0});
        }
        if (periodic && !r.items.empty())
            r.items.front().caption = QString::fromUtf8("Soluciones periódicas · n, k ∈ ℤ");
        else if (r.items.size() > 1 || (list.size() > 1))
            r.items[r.items.size() - list.size()].caption = QString::fromUtf8("%1 soluciones").arg(list.size());
        r.summary = summary.join("; ");
    }

    void numericRoots(const gen &expr, const QString &v, Response &r, std::vector<QPointF> &marks)
    {
        Program p = compileOrThrow(expr, {v});
        std::vector<double> roots;
        const double a = -100, b = 100;
        const int N = 40000;
        double px = a, py = p.eval1(a);
        for (int i = 1; i <= N; ++i) {
            double x = a + (b - a) * i / N, y = p.eval1(x);
            if (std::isfinite(py) && std::isfinite(y) && ((py <= 0 && y >= 0) || (py >= 0 && y <= 0))) {
                double lo = px, hi = x, flo = py;
                for (int k = 0; k < 80; ++k) {
                    double mid = 0.5 * (lo + hi), fm = p.eval1(mid);
                    if ((flo <= 0) == (fm <= 0)) lo = mid, flo = fm;
                    else hi = mid;
                }
                double root = 0.5 * (lo + hi);
                double fr = std::fabs(p.eval1(root));
                if (fr < 1e-6 * std::max(1.0, std::max(std::fabs(py), std::fabs(y))) &&
                    (roots.empty() || std::fabs(roots.back() - root) > 1e-7))
                    roots.push_back(root);
            }
            px = x, py = y;
            if (roots.size() > 30) break;
        }
        if (roots.empty()) {
            ResultItem it;
            it.formula = M::text(QString::fromUtf8("No encuentro soluciones en [−100, 100]"));
            r.items.push_back(it);
            r.summary = it.formula->text;
            return;
        }
        QStringList summary;
        for (double x : roots) {
            QString s = fmtDouble(x, std::min(m_digits, 15));
            ResultItem it;
            it.formula = M::row({idNode(v), M::op(QString::fromUtf8("≈")), numberNode(s)});
            it.text = v + " = " + s;
            r.items.push_back(it);
            summary << it.text;
            marks.push_back({x, 0});
        }
        r.items.front().caption = QString::fromUtf8("Soluciones numéricas (no hay fórmula exacta)");
        r.summary = summary.join("; ");
    }

    bool isLinear(const std::vector<Rel> &rels, const QStringList &vars)
    {
        for (auto &x : rels) {
            for (auto &v : vars) {
                gen d = run("diff(" + P(x.expr) + "," + v + ")");
                for (auto &w : vars)
                    if (P(d).contains(QRegularExpression("\\b" + QRegularExpression::escape(w) + "\\b"))) return false;
            }
        }
        return true;
    }

    void solveSystem(const std::vector<Rel> &eqs, const QStringList &vars, bool complexDomain, Response &r, std::vector<QPointF> &marks)
    {
        QString eqs_ = listSrc(eqList(eqs)), vs = "[" + vars.join(",") + "]";
        if (isLinear(eqs, vars)) {
            QString A = "[", Ab = "[";
            for (size_t i = 0; i < eqs.size(); ++i) {
                QStringList row;
                for (auto &v : vars) row << P(run("diff(" + P(eqs[i].expr) + "," + v + ")"));
                QStringList zero;
                for (auto &v : vars) zero << v + "=0";
                QString b = P(run("-subst(" + P(eqs[i].expr) + ",[" + zero.join(",") + "])"));
                A += (i ? "," : "") + QString("[%1]").arg(row.join(","));
                Ab += (i ? "," : "") + QString("[%1,%2]").arg(row.join(","), b);
            }
            A += "]";
            Ab += "]";
            int rA = run("rank(" + A + ")").val, rAb = run("rank(" + Ab + ")").val;
            ResultItem cls;
            if (rA < rAb) {
                cls.caption = QString::fromUtf8("Sistema incompatible (rango A = %1 < rango A* = %2)").arg(rA).arg(rAb);
                cls.formula = M::text(QString::fromUtf8("No tiene solución"));
                cls.text = "[]";
                r.items.push_back(cls);
                r.summary = QString::fromUtf8("Sistema incompatible");
                return;
            }
            gen sol = run("linsolve(" + eqs_ + "," + vs + ")");
            if (sol.type != giac::_VECT || sol._VECTptr->empty()) throw CasError(QString::fromUtf8("No he podido resolver el sistema."));
            const int free = vars.size() - rA;
            ResultItem it;
            it.caption = free == 0 ? QString::fromUtf8("Sistema compatible determinado (solución única)")
                                   : QString::fromUtf8("Sistema compatible indeterminado · %1 parámetro%2 libre%2 (rango %3)")
                                         .arg(free).arg(free > 1 ? "s" : "").arg(rA);
            QStringList shownVars, freeVars;
            vecteur shownVals;
            for (int k = 0; k < vars.size() && k < int(sol._VECTptr->size()); ++k) {
                const gen &val = (*sol._VECTptr)[k];
                if (P(val) == vars[k]) freeVars << vars[k];
                else shownVars << vars[k], shownVals.push_back(val);
            }
            it.formula = assignRow(shownVars, shownVals);
            if (!freeVars.isEmpty())
                it.formula = M::row({it.formula, M::space(12), M::text(QString::fromUtf8("con  ") + freeVars.join(", ") + QString::fromUtf8(" ∈ ℝ"))});
            it.text = assignText(shownVars, shownVals);
            it.latex = tex(sol);
            r.items.push_back(it);
            r.summary = it.text;
            if (vars.size() == 2 && free == 0) {
                std::complex<double> a, b;
                if (numericValue((*sol._VECTptr)[0], a) && numericValue((*sol._VECTptr)[1], b)) marks.push_back({a.real(), b.real()});
            }
            return;
        }
        gen sols;
        try {
            sols = run(QString("%1(%2,%3)").arg(complexDomain ? "cSolve" : "solve", eqs_, vs));
        } catch (...) {
        }
        std::vector<vecteur> found;
        if (sols.type == giac::_VECT && !hasSommet(sols, "solve")) {
            for (auto &s : *sols._VECTptr)
                if (s.type == giac::_VECT) found.push_back(*evalfIfRootof(s)._VECTptr);
        }
        bool numeric = false;
        if (found.empty() && !complexDomain) {
            numeric = true;
            QSet<QString> seen;
            const double guesses[] = {0.5, -0.5, 2, -2, 5, -5};
            for (double g1 : guesses) {
                for (double g2 : guesses) {
                    QStringList g;
                    for (int k = 0; k < vars.size(); ++k) g << QString::number(k % 2 ? g2 : g1);
                    try {
                        gen s = run(QString("fsolve(%1,%2,[%3])").arg(eqs_, vs, g.join(",")));
                        if (s.type == giac::_VECT && s._VECTptr->size() == size_t(vars.size()) && isNumeric(s._VECTptr->front())) {
                            QStringList key;
                            for (auto &c : *s._VECTptr) key << QString::number(dv(c), 'g', 6);
                            if (!seen.contains(key.join(","))) {
                                seen.insert(key.join(","));
                                found.push_back(*s._VECTptr);
                            }
                        }
                    } catch (...) {
                    }
                    if (found.size() >= 8) break;
                }
                if (found.size() >= 8) break;
            }
        }
        if (found.empty()) {
            ResultItem it;
            it.formula = M::text(QString::fromUtf8("Sin solución"));
            r.items.push_back(it);
            r.summary = QString::fromUtf8("Sin solución");
            return;
        }
        QStringList summary;
        for (auto &v : found) {
            ResultItem it;
            it.formula = assignRow(vars, v);
            it.text = assignText(vars, v);
            it.latex = tex(gen(v, 0));
            r.items.push_back(it);
            summary << it.text;
            std::complex<double> a, b;
            if (vars.size() == 2 && numericValue(v[0], a) && numericValue(v[1], b) && std::abs(a.imag()) < 1e-12 && std::abs(b.imag()) < 1e-12)
                marks.push_back({a.real(), b.real()});
        }
        r.items.front().caption = numeric ? QString::fromUtf8("Soluciones numéricas (%1 encontradas)").arg(found.size())
                                          : QString::fromUtf8("%1 solución(es)").arg(found.size());
        r.summary = summary.join("; ");
    }

    struct Interval {
        gen lo, hi;
        bool loInf = true, hiInf = true, loClosed = false, hiClosed = false, point = false;
    };

    bool toInterval(const gen &piece, const gen &var, Interval &iv)
    {
        if (piece == var) return true;  // whole line
        if (isS(piece, "and")) {
            for (auto &a : args(piece)) {
                Interval sub;
                if (!toInterval(a, var, sub)) return false;
                if (!sub.loInf) iv.lo = sub.lo, iv.loInf = false, iv.loClosed = sub.loClosed;
                if (!sub.hiInf) iv.hi = sub.hi, iv.hiInf = false, iv.hiClosed = sub.hiClosed;
            }
            return true;
        }
        if (isS(piece, "=")) {
            auto a = args(piece);
            iv.point = true;
            iv.lo = a[0] == var ? a[1] : a[0];
            return true;
        }
        gen v, c;
        bool lower, strict;
        if (!bound(piece, v, c, lower, strict) || v != var) return false;
        if (lower) iv.lo = c, iv.loInf = false, iv.loClosed = !strict;
        else iv.hi = c, iv.hiInf = false, iv.hiClosed = !strict;
        return true;
    }

    void solveIneq1(const std::vector<Rel> &rels, const QString &v, Response &r, PlotSpec &ps)
    {
        QStringList src;
        for (auto &x : rels) src << relSrc(x);
        gen sol = run("solve([" + src.join(",") + "]," + v + ")");
        if (sol.type != giac::_VECT) throw CasError(QString::fromUtf8("No he podido resolver la inecuación."));
        gen var = giac::identificateur(v.toStdString());
        if (sol._VECTptr->empty()) {
            ResultItem it;
            it.formula = M::text(QString::fromUtf8("Sin solución"));
            r.items.push_back(it);
            r.summary = QString::fromUtf8("Sin solución");
            return;
        }
        std::vector<MPtr> setParts, relParts;
        Series band;
        band.kind = Series::XBand;
        bool allOk = true;
        for (auto &piece : *sol._VECTptr) {
            Interval iv;
            if (!toInterval(piece, var, iv)) { allOk = false; break; }
            if (!setParts.empty()) setParts.push_back(M::op(QString::fromUtf8("∪")));
            if (iv.point) {
                setParts.push_back(M::paren(node(iv.lo), "{}"));
                double d = dv(iv.lo);
                band.pts.push_back({d, 0});
            } else if (iv.loInf && iv.hiInf) {
                setParts.push_back(M::var(QString::fromUtf8("ℝ")));
                band.intervals.push_back({-INFINITY, INFINITY});
            } else {
                QString kind = QString(iv.loInf || !iv.loClosed ? "(" : "[") + (iv.hiInf || !iv.hiClosed ? ")" : "]");
                MPtr lo = iv.loInf ? M::row({unaryMinus(), M::var(QString::fromUtf8("∞"))}) : node(iv.lo);
                MPtr hi = iv.hiInf ? M::row({unaryOp("+"), M::var(QString::fromUtf8("∞"))}) : node(iv.hi);
                setParts.push_back(M::paren(M::row({lo, M::text(","), M::space(4), hi}), kind));
                band.intervals.push_back({iv.loInf ? -INFINITY : dv(iv.lo), iv.hiInf ? INFINITY : dv(iv.hi)});
            }
            if (!relParts.empty()) relParts.push_back(M::op(QString::fromUtf8("∨")));
            relParts.push_back(node(piece));
        }
        if (allOk) {
            ResultItem it = item(QString::fromUtf8("Solución"), M::row({idNode(v), M::op(QString::fromUtf8("∈")), M::row(setParts)}), sol);
            r.items.push_back(it);
            ps.series.push_back(band);
        }
        r.items.push_back(item(allOk ? QString::fromUtf8("Equivalente a") : QString::fromUtf8("Solución"), M::row(relParts), sol));
        r.summary = P(sol);
    }

    void solveIneq2(const std::vector<Rel> &rels, const QStringList &vars, Response &r, std::vector<QPointF> &marks)
    {
        ResultItem it;
        it.caption = QString::fromUtf8("Región del plano: la solución es la zona sombreada de la gráfica");
        r.items.push_back(it);
        r.summary = QString::fromUtf8("Región del plano");
        if (!isLinear(rels, vars)) return;

        std::vector<Program> progs;
        for (auto &x : rels) progs.push_back(compileOrThrow(x.expr, vars));
        auto feasible = [&](double a, double b) {
            for (size_t i = 0; i < rels.size(); ++i) {
                double d = progs[i].eval2(a, b);
                const double tol = 1e-9 * (1 + std::fabs(a) + std::fabs(b));
                const QString &op = rels[i].op;
                if ((op == "<" || op == "<=") && d > tol) return false;
                if ((op == ">" || op == ">=") && d < -tol) return false;
                if (op == "=" && std::fabs(d) > tol) return false;
            }
            return true;
        };
        std::vector<std::pair<QPointF, gen>> verts;
        for (size_t i = 0; i < rels.size(); ++i) {
            for (size_t j = i + 1; j < rels.size(); ++j) {
                gen s;
                try {
                    s = run(QString("linsolve([%1=0,%2=0],[%3])").arg(P(rels[i].expr), P(rels[j].expr), vars.join(",")));
                } catch (...) {
                    continue;
                }
                if (s.type != giac::_VECT || s._VECTptr->size() != 2 || !isNumeric((*s._VECTptr)[0]) || !isNumeric((*s._VECTptr)[1])) continue;
                QPointF p(dv((*s._VECTptr)[0]), dv((*s._VECTptr)[1]));
                if (!feasible(p.x(), p.y())) continue;
                bool dup = false;
                for (auto &v : verts) dup |= std::hypot(v.first.x() - p.x(), v.first.y() - p.y()) < 1e-9;
                if (!dup) verts.push_back({p, s});
            }
        }
        if (verts.empty()) return;
        double cx = 0, cy = 0;
        for (auto &v : verts) cx += v.first.x(), cy += v.first.y();
        cx /= verts.size(), cy /= verts.size();
        std::sort(verts.begin(), verts.end(), [&](auto &a, auto &b) {
            return std::atan2(a.first.y() - cy, a.first.x() - cx) < std::atan2(b.first.y() - cy, b.first.x() - cx);
        });
        std::vector<MPtr> pts;
        QStringList txt;
        for (auto &v : verts) {
            const vecteur &c = *v.second._VECTptr;
            pts.push_back(M::paren(M::row({node(c[0]), M::text(","), M::space(4), node(c[1])})));
            txt << "(" + P(c[0]) + ", " + P(c[1]) + ")";
            marks.push_back(v.first);
        }
        ResultItem vi;
        vi.caption = QString::fromUtf8("Vértices de la región (%1)").arg(verts.size());
        vi.formula = joinNodes(pts, ",");
        vi.text = txt.join(", ");
        r.items.push_back(vi);
    }

    // -------------------------------------------------------- calculus
    gen userFunction(const QString &raw, QString &shown)
    {
        RelSplit rs = splitRel(raw);
        QString body = raw;
        if (!rs.ops.isEmpty()) {
            if (rs.ops.size() != 1 || (rs.ops[0] != "=" && rs.ops[0] != ":="))
                throw CasError(QString::fromUtf8("Escribe una función, por ejemplo  x^2·sen(x)."));
            body = rs.parts[1];
        }
        shown = body;
        return user(body);
    }

    QString pickVar(const gen &f, const QString &given, int index = 0, const QString &fallback = "x")
    {
        if (!given.trimmed().isEmpty()) return given.trimmed();
        QStringList v = varsOf(f);
        if (index < v.size()) return v[index];
        if (index == 1 && v.size() == 1 && v[0] == "y") return "x";
        return fallback;
    }

    MPtr dvar(const QString &v) { return M::row({M::text("d"), idNode(v)}); }

    // ------------------------------------------- polynomial division
    // Coefficients of f in v, highest power first; throws when f is not a polynomial.
    std::vector<gen> coeffsOf(const gen &f, const QString &v, const QString &what)
    {
        const QString src = P(f);
        bool ok = false;
        std::vector<gen> out;
        try {
            gen c = run(QString("symb2poly(%1,%2)").arg(src, v));
            if (c.type == giac::_VECT) out.assign(c._VECTptr->begin(), c._VECTptr->end());
            else out.push_back(c);
            ok = !out.empty() && P(run(QString("normal(poly2symb(symb2poly(%1,%2),%2)-(%1))").arg(src, v))) == "0";
            for (auto &k : out)
                if (varsOf(k).contains(v)) ok = false;
        } catch (...) {
        }
        if (!ok) throw CasError(what + QString::fromUtf8(" no es un polinomio en ") + v + ".");
        for (auto &k : out) k = run("normal(" + P(k) + ")");
        while (out.size() > 1 && P(out.front()) == "0") out.erase(out.begin());
        return out;
    }

    gen polyOf(const std::vector<gen> &c, const QString &v)
    {
        QStringList l;
        for (auto &k : c) l << P(k);
        return run(QString("normal(poly2symb([%1],%2))").arg(l.join(","), v));
    }

    bool isZero(const gen &g) { return P(g) == "0"; }
    bool negative(const gen &g) { return isNumeric(g) && dv(g) < 0; }

    // c·v^k with its sign in front ("+ 3x²", "− x"); the first term of a row
    // carries no "+".
    MPtr termNode(const gen &c, int k, const QString &v, bool first)
    {
        const bool neg = negative(c);
        gen t = run(QString("(%1)*%2^%3").arg(P(neg ? run("-(" + P(c) + ")") : c), v).arg(k));
        MPtr body = node(isNumeric(c) ? run("normal(" + P(t) + ")") : t);   // keep (a+1)·x² grouped
        if (first) return neg ? M::row({M::text(QString::fromUtf8("−")), body}) : body;
        return M::row({M::text(neg ? QString::fromUtf8("− ") : "+ "), body});
    }

    // A polynomial as a row of terms (zeros left out).
    MPtr polyNode(const std::vector<gen> &c, const QString &v)
    {
        std::vector<MPtr> row;
        const int deg = int(c.size()) - 1;
        for (int i = 0; i <= deg; ++i) {
            if (isZero(c[i])) continue;
            if (!row.empty()) row.push_back(M::space(3));
            row.push_back(termNode(c[i], deg - i, v, row.empty()));
        }
        return row.empty() ? M::num("0") : M::row(row);
    }

    // Rational roots of the polynomial with coefficients c, by the Ruffini
    // rule of thumb: divisors of the constant term over those of the leader.
    std::vector<gen> rationalRoots(const std::vector<gen> &c)
    {
        std::vector<gen> roots;
        if (c.size() < 2) return roots;
        if (isZero(c.back())) return {gen(0)};
        try {
            gen rr = run("rationalroot(" + P(polyOf(c, "x")) + ")");
            if (rr.type == giac::_VECT)
                for (auto &x : *rr._VECTptr)
                    if (isNumeric(x)) roots.push_back(x);
        } catch (...) {
        }
        std::sort(roots.begin(), roots.end(), [this](const gen &a, const gen &b) {
            double x = dv(a), y = dv(b);
            return std::fabs(x) != std::fabs(y) ? std::fabs(x) < std::fabs(y) : x > y;
        });
        return roots;
    }

    // One synthetic division of c by (v − a): the table and the quotient.
    MPtr ruffiniTable(const std::vector<gen> &c, const gen &a, std::vector<gen> &quot, gen &rest)
    {
        const int n = int(c.size());
        std::vector<gen> b(n), prod(n);
        b[0] = c[0];
        for (int i = 1; i < n; ++i) {
            prod[i] = run(QString("normal((%1)*(%2))").arg(P(a), P(b[i - 1])));
            b[i] = run(QString("normal((%1)+(%2))").arg(P(c[i]), P(prod[i])));
        }
        std::vector<MPtr> cells;
        cells.push_back(M::row({}));
        for (auto &k : c) cells.push_back(node(k));
        cells.push_back(node(a));
        cells.push_back(M::row({}));
        for (int i = 1; i < n; ++i) cells.push_back(node(prod[i]));
        cells.push_back(M::row({}));
        for (auto &k : b) cells.push_back(node(k));
        quot.assign(b.begin(), b.end() - 1);
        rest = b.back();
        auto t = std::make_shared<MNode>(*M::matrix(n + 1, cells));
        t->text = "ruffini";
        return t;
    }

    MPtr linFactor(const QString &v, const gen &a)
    {
        if (isZero(a)) return idNode(v);
        const bool neg = negative(a);
        return M::paren(M::row({idNode(v), M::op(neg ? "+" : QString::fromUtf8("−")), node(neg ? run("-(" + P(a) + ")") : a)}));
    }

    void polyDivision(bool ruffini, const QVariantMap &pm, Response &r, PlotSpec &ps)
    {
        QString shown;
        gen f = userFunction(pm.value("f").toString(), shown);
        const QString gsrc = pm.value("g").toString().trimmed();
        gen g = gsrc.isEmpty() ? gen(0) : user(gsrc);
        QString v = pm.value("var").toString().trimmed();
        if (v.isEmpty()) {
            QStringList all = varsOf(gsrc.isEmpty() ? f : run("[" + P(f) + "," + P(g) + "]"));
            v = all.contains("x") || all.isEmpty() ? "x" : all[0];
        }
        std::vector<gen> c = coeffsOf(f, v, QString::fromUtf8("El dividendo"));
        const int D = int(c.size()) - 1;
        MPtr Pn = M::row({M::var("P"), M::paren(idNode(v))});
        auto curve = [&](const gen &h, MPtr label, bool dashed) {
            Series s;
            s.kind = Series::Func;
            s.p.push_back(compileOrThrow(h, {v}));
            s.label = label;
            s.dashed = dashed;
            ps.series.push_back(s);
        };

        if (ruffini) {
            if (D < 1) throw CasError(QString::fromUtf8("Ruffini necesita un polinomio de grado 1 o más."));
            std::vector<gen> roots;
            gen lead = 1;
            bool factorMode = gsrc.isEmpty();
            if (!factorMode) {
                // "x − a", "2x − 1" or just the number a
                std::vector<gen> d = varsOf(g).contains(v) ? coeffsOf(g, v, QString::fromUtf8("El divisor")) : std::vector<gen>{1, run("-(" + P(g) + ")")};
                if (d.size() != 2) throw CasError(QString::fromUtf8("Ruffini divide entre binomios  ") + v + QString::fromUtf8(" − a  (grado 1). Para otros divisores usa «División de polinomios»."));
                lead = d[0];
                roots.push_back(run(QString("normal(-(%1)/(%2))").arg(P(d[1]), P(d[0]))));
            }
            std::vector<gen> cur = c, found;
            for (int step = 0; step < 40 && cur.size() > 1; ++step) {
                gen a;
                if (factorMode) {
                    std::vector<gen> rr = rationalRoots(cur);
                    if (rr.empty()) break;
                    a = rr[0];
                } else {
                    if (step > 0) break;
                    a = roots[0];
                }
                std::vector<gen> q;
                gen rest;
                MPtr table = ruffiniTable(cur, a, q, rest);
                ResultItem it;
                it.caption = QString::fromUtf8("Ruffini: división entre ") + (isZero(a) ? v : QString("%1 %2 %3").arg(v, negative(a) ? "+" : QString::fromUtf8("−"), P(negative(a) ? run("-(" + P(a) + ")") : a)));
                it.formula = table;
                it.text = QString("ruffini: a = %1 → cociente %2, resto %3").arg(P(a), P(polyOf(q, v)), P(rest));
                r.items.push_back(it);
                if (!factorMode) {
                    ResultItem qi = item(QString::fromUtf8("Cociente"), M::row({M::var("C"), M::paren(idNode(v)), M::op("="), polyNode(q, v)}), polyOf(q, v));
                    r.items.push_back(qi);
                    r.items.push_back(item(QString::fromUtf8("Resto (teorema del resto: P(a) = R)"),
                                           M::row({M::var("R"), M::op("="), M::row({M::var("P"), M::paren(node(a))}), M::op("="), node(rest)}), rest));
                    gen Q = polyOf(q, v);
                    std::vector<MPtr> id = {Pn, M::op("="), linFactor(v, a), M::text(QString::fromUtf8("·")), M::paren(polyNode(q, v))};
                    if (!isZero(rest)) id.insert(id.end(), {M::op(negative(rest) ? QString::fromUtf8("−") : "+"), node(negative(rest) ? run("-(" + P(rest) + ")") : rest)});
                    if (!isZero(rest)) r.items.push_back(item(QString::fromUtf8("Comprobación: P = (x − a)·C + R"), M::row(id), run(QString("(%1-(%2))*(%3)+(%4)").arg(v, P(a), P(Q), P(rest)))));
                    if (!isZero(lead) && P(lead) != "1") {
                        gen Q2 = run(QString("normal((%1)/(%2))").arg(P(Q), P(lead)));
                        r.items.push_back(item(QString::fromUtf8("Dividiendo entre ") + P(g) + QString::fromUtf8(" (el cociente se divide entre ") + P(lead) + ")",
                                               M::row({M::var("C"), M::op("="), node(Q2)}), Q2));
                    }
                    r.summary = QString("C = %1, R = %2").arg(P(Q), P(rest));
                    if (isZero(rest)) r.items.push_back(item(QString::fromUtf8("Resto 0: ") + P(a) + QString::fromUtf8(" es raíz y (") + v + QString::fromUtf8(" − a) divide a P"),
                                                             M::row({Pn, M::op("="), linFactor(v, a), M::text(QString::fromUtf8("·")), M::paren(polyNode(q, v))}), f));
                    curve(f, Pn, false);
                    Series pt;
                    pt.kind = Series::Points;
                    double ax = dv(a), ry = dv(rest);
                    if (std::isfinite(ax) && std::isfinite(ry)) pt.pts.push_back({ax, ry});
                    pt.label = M::row({M::var("P"), M::paren(node(a)), M::op("="), node(rest)});
                    ps.series.push_back(pt);
                    ps.xmin = ax - 5, ps.xmax = ax + 5;
                    break;
                }
                found.push_back(a);
                cur = q;
            }
            if (factorMode) {
                if (found.empty()) {
                    ResultItem it;
                    it.caption = QString::fromUtf8("Sin raíces racionales (ningún divisor del término independiente entre los del coeficiente principal anula P)");
                    it.formula = M::text(QString::fromUtf8("Ruffini no puede factorizarlo"));
                    it.text = P(f);
                    r.items.push_back(it);
                    r.summary = P(f);
                } else {
                    // P = lead · ∏ (v − a) · rest, equal roots grouped as powers
                    std::vector<MPtr> prod;
                    gen restPoly = polyOf(cur, v);
                    if (cur.size() == 1 && P(cur[0]) != "1") prod.push_back(node(cur[0]));
                    for (size_t i = 0; i < found.size();) {
                        size_t k = i;
                        while (k < found.size() && P(found[k]) == P(found[i])) ++k;
                        MPtr fac = linFactor(v, found[i]);
                        prod.push_back(k - i > 1 ? M::pow(fac, M::num(QString::number(k - i))) : fac);
                        i = k;
                    }
                    if (cur.size() > 1) prod.push_back(M::paren(polyNode(cur, v)));
                    gen fac = run("factor(" + P(f) + ")");
                    r.items.push_back(item(QString::fromUtf8("Factorización por Ruffini"), M::row({Pn, M::op("="), M::row(prod)}), fac));
                    QStringList rs;
                    for (auto &a : found) rs << P(a);
                    ResultItem ri;
                    ri.caption = QString::fromUtf8("Raíces racionales");
                    std::vector<MPtr> row;
                    for (size_t i = 0; i < found.size(); ++i) {
                        if (i) row.push_back(M::text(",  "));
                        row.push_back(M::row({M::sub(idNode(v), M::num(QString::number(i + 1))), M::op("="), node(found[i])}));
                    }
                    ri.formula = M::row(row);
                    ri.text = rs.join(", ");
                    r.items.push_back(ri);
                    if (cur.size() > 2)
                        r.items.push_back(item(QString::fromUtf8("El último cociente no tiene raíces racionales"), polyNode(cur, v), restPoly));
                    r.summary = P(fac);
                    curve(f, Pn, false);
                    Series pt;
                    pt.kind = Series::Points;
                    double lo = 0, hi = 0;
                    for (auto &a : found) {
                        double x = dv(a);
                        pt.pts.push_back({x, 0});
                        lo = std::min(lo, x), hi = std::max(hi, x);
                    }
                    pt.label = M::text(QString::fromUtf8("raíces"));
                    ps.series.push_back(pt);
                    ps.xmin = lo - 3, ps.xmax = hi + 3;
                    // fit y to the bumps between the roots, not to the steep ends
                    const Program &pp = ps.series.front().p[0];
                    double ylo = -1, yhi = 1;
                    for (int i = 0; i <= 200; ++i) {
                        double y = pp.eval1(lo - 0.5 + (hi - lo + 1) * i / 200.0);
                        if (std::isfinite(y)) ylo = std::min(ylo, y), yhi = std::max(yhi, y);
                    }
                    const double m = (yhi - ylo) * 0.25;
                    ps.ymin = ylo - m, ps.ymax = yhi + m;
                }
            }
            ps.xname = v;
            return;
        }

        // ---- long division
        if (gsrc.isEmpty()) throw CasError(QString::fromUtf8("Escribe el divisor."));
        std::vector<gen> d = coeffsOf(g, v, QString::fromUtf8("El divisor"));
        if (d.size() == 1 && isZero(d[0])) throw CasError(QString::fromUtf8("No se puede dividir entre 0."));
        const int dd = int(d.size()) - 1;
        std::vector<gen> rem = c, q;
        const int cols = D + 2;
        auto empty = [] { return M::row({}); };
        std::vector<std::vector<MPtr>> rows;
        std::vector<int> rules;
        auto newRow = [&] { rows.push_back(std::vector<MPtr>(cols, nullptr)); return int(rows.size()) - 1; };
        auto fillTerms = [&](int row, const std::vector<gen> &vals, int from, int to) {
            bool first = true;
            for (int i = from; i <= to && i <= D; ++i) {
                if (isZero(vals[i])) continue;
                rows[row][i] = termNode(vals[i], D - i, v, first);
                first = false;
            }
        };
        int r0 = newRow();
        fillTerms(r0, c, 0, D);
        rows[r0][cols - 1] = polyNode(d, v);
        for (int k = 0; k + dd <= D; ++k) {
            if (isZero(rem[k])) {
                q.push_back(gen(0));
                continue;
            }
            gen qk = run(QString("normal((%1)/(%2))").arg(P(rem[k]), P(d[0])));
            q.push_back(qk);
            std::vector<gen> sub(D + 1, gen(0));
            for (int j = 0; j <= dd; ++j) {
                sub[k + j] = run(QString("normal(-(%1)*(%2))").arg(P(qk), P(d[j])));
                rem[k + j] = run(QString("normal((%1)+(%2))").arg(P(rem[k + j]), P(sub[k + j])));
            }
            rem[k] = gen(0);
            int rs = newRow();
            fillTerms(rs, sub, k, k + dd);
            int rr = newRow();
            rules.push_back(rr);
            fillTerms(rr, rem, k + 1, D);
            if (!rows[rr][0] && std::all_of(rows[rr].begin(), rows[rr].end() - 1, [](const MPtr &m) { return !m; }))
                rows[rr][D] = M::num("0");
        }
        if (q.empty()) q.push_back(gen(0));
        if (rows.size() > 1) rows[1][cols - 1] = polyNode(q, v);
        std::vector<gen> rtail(rem.begin() + std::max(0, D - dd + 1), rem.end());
        if (dd == 0 || rtail.empty()) rtail = {gen(0)};
        gen Q = polyOf(q, v), R = polyOf(rtail, v);
        if (rows.size() > 1) {
            std::vector<MPtr> cells;
            for (auto &row : rows)
                for (auto &m : row) cells.push_back(m ? m : empty());
            QStringList rl;
            for (int x : rules) rl << QString::number(x);
            auto t = std::make_shared<MNode>(*M::matrix(cols, cells));
            t->text = "longdiv:" + rl.join(",");
            ResultItem it;
            it.caption = QString::fromUtf8("División paso a paso");
            it.formula = t;
            it.text = QString("quorem(%1,%2,%3) = [%4, %5]").arg(P(f), P(g), v, P(Q), P(R));
            r.items.push_back(it);
        }
        MPtr Dn = M::paren(polyNode(d, v));
        r.items.push_back(item(QString::fromUtf8("Cociente"), M::row({M::var("C"), M::paren(idNode(v)), M::op("="), node(Q)}), Q));
        r.items.push_back(item(QString::fromUtf8("Resto"), M::row({M::var("R"), M::paren(idNode(v)), M::op("="), node(R)}), R));
        // "+ R" or "− (−R)" when R starts negative, never "+ −2x"
        size_t lead = 0;
        while (lead + 1 < rtail.size() && isZero(rtail[lead])) ++lead;
        const bool rneg = negative(rtail[lead]);
        MPtr absR = node(rneg ? run("normal(-(" + P(R) + "))") : R);
        MPtr rSign = M::op(rneg ? QString::fromUtf8("−") : "+");
        std::vector<MPtr> id = {M::paren(polyNode(c, v)), M::op("="), Dn, M::text(QString::fromUtf8("·")), M::paren(node(Q))};
        if (!isZero(R)) id.insert(id.end(), {rSign, rtail.size() - lead > 1 && rneg ? M::paren(absR) : absR});
        r.items.push_back(item(QString::fromUtf8("Comprobación: D = d·C + R"), M::row(id), run(QString("(%1)*(%2)+(%3)").arg(P(g), P(Q), P(R)))));
        if (!isZero(R) && dd > 0) {
            gen quo = run(QString("(%1)+(%2)/(%3)").arg(P(Q), P(R), P(g)));
            r.items.push_back(item(QString::fromUtf8("Como fracción"),
                                   M::row({M::frac(polyNode(c, v), polyNode(d, v)), M::op("="), node(Q), rSign, M::frac(absR, polyNode(d, v))}), quo));
        } else if (isZero(R)) {
            ResultItem ex;
            ex.caption = QString::fromUtf8("División exacta: el divisor es factor del dividendo");
            ex.formula = M::row({M::paren(polyNode(c, v)), M::op("="), Dn, M::text(QString::fromUtf8("·")), M::paren(node(Q))});
            ex.text = P(Q);
            r.items.push_back(ex);
        }
        r.summary = QString("C = %1, R = %2").arg(P(Q), P(R));
        if (dd > 0) {
            curve(run(QString("(%1)/(%2)").arg(P(f), P(g))), M::frac(M::var("D"), M::var("d")), false);
            if (!isZero(R)) curve(Q, M::row({M::var("C"), M::paren(idNode(v)), M::text(q.size() <= 2 ? QString::fromUtf8("  (asíntota)") : QString())}), true);
        } else {
            curve(f, M::var("D"), false);
            curve(Q, M::var("C"), true);
        }
        ps.xname = v;
        ps.xmin = -8, ps.xmax = 8;
    }

    void calculus(const Request &rq, Response &r)
    {
        const QVariantMap &pm = rq.params;
        const QString op = pm.value("op").toString();
        if (op == "polydiv" || op == "ruffini") {
            auto ps = std::make_shared<PlotSpec>();
            polyDivision(op == "ruffini", pm, r, *ps);
            if (!ps->series.empty()) r.plot = ps;
            return;
        }
        QString shown;
        gen f = userFunction(pm.value("f").toString(), shown);
        QStringList fv = varsOf(f);
        auto ps = std::make_shared<PlotSpec>();
        auto fnSeries = [&](const gen &g, const QString &v, MPtr label, bool dashed = false) {
            Series s;
            s.kind = Series::Func;
            s.p.push_back(compileOrThrow(g, {v}));
            s.label = label;
            s.dashed = dashed;
            ps->series.push_back(s);
        };
        auto surface = [&](const gen &g, const QStringList &v) {
            Series s;
            s.kind = Series::Surface;
            s.p.push_back(compileOrThrow(g, v));
            s.label = node(g);
            ps->is3D = true;
            ps->xname = v[0];
            ps->yname = v[1];
            ps->xmin = -4, ps->xmax = 4, ps->ymin = -4, ps->ymax = 4;
            ps->series.push_back(s);
        };
        MPtr fN = node(f);
        auto fLabel = [&](const QString &v, const QString &primes = QString()) {
            if (primes.isEmpty()) return M::row({M::var("f"), M::paren(idNode(v))});
            return M::row({M::var("f"), M::text(primes), M::paren(idNode(v))});
        };

        if (op == "diff") {
            QStringList vl = pm.value("var").toString().split(QRegularExpression("[,;\\s]+"), Qt::SkipEmptyParts);
            if (vl.isEmpty()) vl << pickVar(f, {});
            int order = std::max(1, pm.value("order").toInt());
            if (vl.size() == 1) for (int i = 1; i < order; ++i) vl << vl[0];
            gen d = f;
            for (auto &v : vl) d = run("diff(" + P(d) + "," + v + ")");
            std::vector<std::pair<QString, gen>> alts;
            gen b = best(d, &alts);
            const bool partial = fv.size() > 1;
            const QString dch = partial ? QString::fromUtf8("∂") : "d";
            MPtr top = vl.size() > 1 ? M::pow(M::text(dch), M::num(QString::number(vl.size()))) : M::text(dch);
            std::vector<MPtr> bottom;
            QStringList uniq;
            for (int i = 0; i < vl.size();) {
                int k = i;
                while (k < vl.size() && vl[k] == vl[i]) ++k;
                MPtr vn = idNode(vl[i]);
                bottom.push_back(M::row({M::text(dch), k - i > 1 ? M::pow(vn, M::num(QString::number(k - i))) : vn}));
                i = k;
            }
            MPtr lhs = M::row({M::frac(top, M::row(bottom)), M::paren(fN)});
            ResultItem it = item(QString::fromUtf8("Derivada"), M::row({lhs, M::op("="), node(b)}), b);
            r.items.push_back(it);
            for (auto &a : alts) r.items.push_back(item(a.first, node(a.second), a.second));
            r.summary = P(b);
            if (fv.size() <= 1) {
                QString v = vl[0];
                fnSeries(f, v, fLabel(v));
                fnSeries(b, v, fLabel(v, QString(std::min(order, 3), QChar(0x2032))));
                ps->xname = v;
                ps->xmin = -6, ps->xmax = 6;
            } else if (fv.size() == 2) {
                surface(f, fv);
            }
        } else if (op == "int") {
            QString v = pickVar(f, pm.value("var").toString());
            gen F = run("integrate(" + P(f) + "," + v + ")");
            std::vector<std::pair<QString, gen>> alts;
            gen b = best(F, &alts);
            bool elementary = !hasSommet(b, "integrate");
            MPtr lhs = M::bigop(QString::fromUtf8("∫"), M::row({wrap(f, P_SUM + 1), M::space(3), dvar(v)}), nullptr, nullptr);
            ResultItem it = item(elementary ? QString::fromUtf8("Primitiva") : QString::fromUtf8("No tiene primitiva elemental: queda indicada"),
                                 M::row({lhs, M::op("="), node(b), M::op("+"), M::var("C")}), b);
            r.items.push_back(it);
            for (auto &a : alts) r.items.push_back(item(a.first, M::row({node(a.second), M::op("+"), M::var("C")}), a.second));
            r.summary = P(b) + " + C";
            if (fv.size() <= 1) {
                fnSeries(f, v, fLabel(v));
                if (elementary) fnSeries(b, v, M::row({M::var("F"), M::paren(idNode(v))}));
                ps->xname = v;
                ps->xmin = -6, ps->xmax = 6;
            } else if (fv.size() == 2) {
                surface(f, fv);
            }
        } else if (op == "defint" || op == "double") {
            QString v = pickVar(f, pm.value("var").toString());
            gen a = user(pm.value("a").toString()), b = user(pm.value("b").toString());
            gen I;
            MPtr lhs;
            if (op == "defint") {
                I = run(QString("integrate(%1,%2,%3,%4)").arg(P(f), v, P(a), P(b)));
                lhs = M::bigop(QString::fromUtf8("∫"), M::row({wrap(f, P_SUM + 1), M::space(3), dvar(v)}), node(a), node(b));
            } else {
                QString v2 = pickVar(f, pm.value("var2").toString(), 1, "y");
                gen c = user(pm.value("c").toString()), d = user(pm.value("d").toString());
                I = run(QString("integrate(integrate(%1,%2,%3,%4),%5,%6,%7)").arg(P(f), v, P(a), P(b), v2, P(c), P(d)));
                MPtr inner = M::bigop(QString::fromUtf8("∫"), M::row({wrap(f, P_SUM + 1), M::space(3), dvar(v)}), node(a), node(b));
                lhs = M::bigop(QString::fromUtf8("∫"), M::row({inner, M::space(3), dvar(v2)}), node(c), node(d));
                if (varsOf(f).size() <= 2) {
                    QStringList sv = {v, v2};
                    surface(f, sv);
                }
            }
            gen b2 = best(I);
            bool exact = !hasSommet(b2, "integrate");
            std::vector<MPtr> row = {lhs, M::op("=")};
            QString approx;
            MPtr ap;
            try { ap = approxNode(b2, &approx); } catch (...) {}
            if (exact) row.push_back(node(b2));
            if (ap && (!exact || approx != P(b2))) {
                if (exact) row.push_back(M::op(QString::fromUtf8("≈")));
                else row.back() = M::op(QString::fromUtf8("≈"));
                row.push_back(ap);
            }
            ResultItem it = item(exact ? QString::fromUtf8("Integral definida") : QString::fromUtf8("Integral definida (valor numérico)"), M::row(row), b2);
            if (!exact && !approx.isEmpty()) it.text = approx;
            r.items.push_back(it);
            r.summary = it.text;
            if (op == "defint" && fv.size() <= 1) {
                double da = dv(a), db = dv(b);
                fnSeries(f, v, fLabel(v));
                if (std::isfinite(da) && std::isfinite(db)) {
                    Series s;
                    s.kind = Series::Fill;
                    s.p.push_back(compileOrThrow(f, {v}));
                    s.a = std::min(da, db);
                    s.b = std::max(da, db);
                    ps->series.push_back(s);
                    double w = std::max(s.b - s.a, 1.0);
                    ps->xmin = s.a - w * 0.5, ps->xmax = s.b + w * 0.5;
                } else {
                    ps->xmin = -10, ps->xmax = 10;
                }
                ps->xname = v;
            }
        } else if (op == "limit") {
            QString v = pickVar(f, pm.value("var").toString());
            gen p = user(pm.value("point").toString().isEmpty() ? "0" : pm.value("point").toString());
            int dir = pm.value("dir").toInt();
            auto lim = [&](int d) { return run(QString("limit(%1,%2,%3,%4)").arg(P(f), v, P(p)).arg(d)); };
            auto sideNode = [&](int d) {
                MPtr pt = node(p);
                if (d) pt = M::pow(pt, M::text(d > 0 ? "+" : QString::fromUtf8("−")));
                return M::under(M::text(QString::fromUtf8("lím")), M::row({idNode(v), M::op(QString::fromUtf8("→")), pt}));
            };
            gen L;
            if (dir == 0) {
                gen lp = lim(1), lm = lim(-1);
                if (P(lp) != P(lm)) {
                    ResultItem no;
                    no.caption = QString::fromUtf8("El límite no existe: los límites laterales son distintos");
                    no.formula = M::row({sideNode(-1), M::space(3), wrap(f, P_PROD), M::op("="), node(lm)});
                    no.text = P(lm);
                    r.items.push_back(no);
                    r.items.push_back(item({}, M::row({sideNode(1), M::space(3), wrap(f, P_PROD), M::op("="), node(lp)}), lp));
                    r.summary = QString::fromUtf8("No existe (%1 ≠ %2)").arg(P(lm), P(lp));
                    L = giac::undef;
                } else {
                    L = lp;
                }
            } else {
                L = lim(dir);
            }
            if (!giac::is_undef(L)) {
                std::vector<MPtr> row = {sideNode(dir), M::space(3), wrap(f, P_PROD), M::op("="), node(L)};
                QString approx;
                if (isNumeric(L) && L.type != giac::_INT_) {
                    MPtr ap = approxNode(L, &approx);
                    if (approx != P(L)) row.insert(row.end(), {M::op(QString::fromUtf8("≈")), ap});
                }
                r.items.push_back(item(QString::fromUtf8("Límite"), M::row(row), L));
                r.summary = P(L);
            }
            if (fv.size() <= 1) {
                double px = dv(p);
                fnSeries(f, v, fLabel(v));
                ps->xname = v;
                if (std::isfinite(px)) {
                    ps->xmin = px - 5, ps->xmax = px + 5;
                    double ly = giac::is_undef(L) ? NAN : dv(L);
                    if (std::isfinite(ly)) {
                        Series s;
                        s.kind = Series::Points;
                        s.pts.push_back({px, ly});
                        ps->series.push_back(s);
                    }
                } else {
                    ps->xmin = -50, ps->xmax = 50;
                }
            }
        } else if (op == "taylor") {
            QString v = pickVar(f, pm.value("var").toString());
            gen a = user(pm.value("point").toString().isEmpty() ? "0" : pm.value("point").toString());
            int n = std::max(1, pm.value("order").toInt());
            gen s = run(QString("series(%1,%2=%3,%4)").arg(P(f), v, P(a)).arg(n));
            vecteur poly;
            if (isS(s, "+")) {
                for (auto &t : args(s))
                    if (!hasSommet(t, "order_size")) poly.push_back(t);
            } else if (!hasSommet(s, "order_size")) {
                poly.push_back(s);
            }
            gen P_ = poly.empty() ? gen(0) : ev(giac::symbolic(giac::at_plus, gen(poly, giac::_SEQ__VECT)));
            r.items.push_back(item(QString::fromUtf8("Desarrollo de Taylor de orden %1 en %2 = %3").arg(n).arg(v, P(a)),
                                   M::row({fN, M::op("="), node(s)}), s));
            r.items.push_back(item(QString::fromUtf8("Polinomio de Taylor"), M::row({M::sub(M::var("T"), M::num(QString::number(n))), M::paren(idNode(v)), M::op("="), node(P_)}), P_));
            r.summary = P(P_);
            if (fv.size() <= 1) {
                double ax = dv(a);
                if (!std::isfinite(ax)) ax = 0;
                fnSeries(f, v, fLabel(v));
                fnSeries(P_, v, M::sub(M::var("T"), M::num(QString::number(n))), true);
                ps->xname = v;
                ps->xmin = ax - 4, ps->xmax = ax + 4;
            }
        } else if (op == "sum") {
            QString v = pm.value("var").toString().trimmed();
            if (v.isEmpty()) v = fv.contains("n") ? "n" : pickVar(f, {}, 0, "n");
            gen a = user(pm.value("a").toString()), b = user(pm.value("b").toString());
            gen S = run(QString("sum(%1,%2,%3,%4)").arg(P(f), v, P(a), P(b)));
            gen bS = best(S);
            std::vector<MPtr> row = {M::bigop(QString::fromUtf8("∑"), wrap(f, P_PROD), M::row({idNode(v), M::op("="), node(a)}), node(b)), M::op("="), node(bS)};
            QString approx;
            if (isNumeric(bS) && bS.type != giac::_INT_) {
                MPtr ap = approxNode(bS, &approx);
                if (approx != P(bS)) row.insert(row.end(), {M::op(QString::fromUtf8("≈")), ap});
            }
            r.items.push_back(item(QString::fromUtf8("Sumatorio"), M::row(row), bS));
            r.summary = P(bS);
            ps.reset();
        } else if (op == "grad") {
            QStringList vl = pm.value("var").toString().split(QRegularExpression("[,;\\s]+"), Qt::SkipEmptyParts);
            if (vl.isEmpty()) vl = fv;
            if (vl.isEmpty()) vl << "x";
            QString vs = "[" + vl.join(",") + "]";
            gen g = run("simplify(grad(" + P(f) + "," + vs + "))");
            gen h = run("simplify(hessian(" + P(f) + "," + vs + "))");
            int seqPrec;
            MPtr comps = conv(gen(*g._VECTptr, giac::_SEQ__VECT), seqPrec);
            r.items.push_back(item(QString::fromUtf8("Gradiente"), M::row({M::text(QString::fromUtf8("∇")), M::var("f"), M::op("="), M::paren(comps)}), g));
            r.items.push_back(item(QString::fromUtf8("Matriz hessiana"), M::row({M::var("H"), M::op("="), node(h)}), h));
            r.summary = P(g);
            // Critical points and their nature (2 variables).
            if (vl.size() == 2) {
                try {
                    QStringList eqs;
                    for (auto &c : *g._VECTptr) eqs << P(c) + "=0";
                    gen cps = run("solve([" + eqs.join(",") + "]," + vs + ")");
                    if (cps.type == giac::_VECT && !cps._VECTptr->empty() && cps._VECTptr->size() <= 12) {
                        bool first = true;
                        for (auto &cp0 : *cps._VECTptr) {
                            gen cp = evalfIfRootof(cp0);
                            if (cp.type != giac::_VECT || cp._VECTptr->size() != 2) continue;
                            QString sub = QString("[%1=%2,%3=%4]").arg(vl[0], P((*cp._VECTptr)[0]), vl[1], P((*cp._VECTptr)[1]));
                            double det = dv(run("subst(det(" + P(h) + ")," + sub + ")"));
                            double fxx = dv(run("subst(" + P((*h._VECTptr)[0]._VECTptr->front()) + "," + sub + ")"));
                            QString kind = !std::isfinite(det) ? QString::fromUtf8("?")
                                           : det > 0 ? (fxx > 0 ? QString::fromUtf8("mínimo relativo") : QString::fromUtf8("máximo relativo"))
                                           : det < 0 ? QString::fromUtf8("punto de silla")
                                                     : QString::fromUtf8("criterio no concluyente");
                            gen fv_ = best(run("subst(" + P(f) + "," + sub + ")"));
                            ResultItem it;
                            if (first) it.caption = QString::fromUtf8("Puntos críticos (∇f = 0)");
                            first = false;
                            it.formula = M::row({M::paren(M::row({node((*cp._VECTptr)[0]), M::text(","), M::space(4), node((*cp._VECTptr)[1])})),
                                                 M::space(6), M::text(QString::fromUtf8("→  ") + kind + ",  "), M::var("f"), M::op("="), node(fv_)});
                            it.text = QString("(%1, %2): %3, f = %4").arg(P((*cp._VECTptr)[0]), P((*cp._VECTptr)[1]), kind, P(fv_));
                            r.items.push_back(it);
                        }
                    }
                } catch (...) {
                }
                surface(f, vl);
            }
        } else {
            throw CasError(QString::fromUtf8("Operación desconocida."));
        }
        if (ps && !ps->series.empty()) r.plot = ps;
    }

    // ------------------------------------------------------------ plot
    bool topLevelTuple(const QString &s, QStringList &comps)
    {
        QString t = s.trimmed();
        if (!t.startsWith('(') || !t.endsWith(')')) return false;
        int depth = 0;
        for (int i = 0; i < t.size(); ++i) {
            if (t[i] == '(' || t[i] == '[') ++depth;
            else if (t[i] == ')' || t[i] == ']') {
                if (--depth == 0 && i != t.size() - 1) return false;
            }
        }
        comps.clear();
        depth = 0;
        int start = 1;
        for (int i = 1; i < t.size() - 1; ++i) {
            if (t[i] == '(' || t[i] == '[') ++depth;
            else if (t[i] == ')' || t[i] == ']') --depth;
            else if (t[i] == ',' && depth == 0) {
                comps << t.mid(start, i - start);
                start = i + 1;
            }
        }
        comps << t.mid(start, t.size() - 1 - start);
        return comps.size() >= 2;
    }

    static bool subset(const QStringList &a, const QStringList &b)
    {
        for (auto &x : a)
            if (!b.contains(x)) return false;
        return true;
    }

    void classify(const QString &raw, PlotSpec &ps, int color, QString &paramVar)
    {
        Series s;
        s.color = color;
        QStringList comps;
        if (topLevelTuple(raw, comps)) {
            if (comps.size() > 3) throw CasError(QString::fromUtf8("Una curva paramétrica tiene 2 o 3 componentes."));
            std::vector<gen> g;
            QStringList vars;
            for (auto &c : comps) {
                g.push_back(user(c));
                for (auto &v : varsOf(g.back()))
                    if (!vars.contains(v)) vars << v;
            }
            if (vars.size() > 1) throw CasError(QString::fromUtf8("Una curva paramétrica usa un solo parámetro (t)."));
            QString t = vars.isEmpty() ? "t" : vars[0];
            paramVar = t;
            for (auto &x : g) s.p.push_back(compileOrThrow(x, {t}));
            s.kind = comps.size() == 2 ? Series::Param2 : Series::Param3;
            std::vector<MPtr> parts;
            for (auto &x : g) parts.push_back(node(x));
            s.label = M::paren(joinNodes(parts, ","));
            ps.series.push_back(s);
            return;
        }
        RelSplit rs = splitRel(raw);
        if (rs.ops.contains(":=")) throw CasError(QString::fromUtf8("Para definir funciones usa la pestaña Científica."));
        s.label = userNode(raw);
        const QStringList xy = {"x", "y"};
        if (rs.ops.size() == 1 && rs.ops[0] == "=") {
            gen L = user(rs.parts[0]), R = user(rs.parts[1]);
            QStringList vl = varsOf(L), vr = varsOf(R);
            static const QRegularExpression fx("^\\s*[A-Za-z_]\\w*\\s*\\(\\s*x\\s*\\)\\s*$");
            if ((P(L) == "y" || fx.match(rs.parts[0]).hasMatch()) && subset(vr, {"x"})) {
                s.kind = Series::Func;
                s.p.push_back(compileOrThrow(R, {"x"}));
                s.complexParts = hasComplexConst(R);
                ps.series.push_back(s);
                return;
            }
            if (P(L) == "z" && subset(vr, xy)) {
                s.kind = Series::Surface;
                s.p.push_back(compileOrThrow(R, xy));
                ps.series.push_back(s);
                return;
            }
            gen E = ev(giac::symbolic(giac::at_plus, gen(giac::makevecteur(L, -R), giac::_SEQ__VECT)));
            QStringList ve = varsOf(E);
            if (ve.contains("z") && subset(ve, {"x", "y", "z"})) {
                s.kind = Series::Implicit3;
                s.p.push_back(compileOrThrow(E, {"x", "y", "z"}));
                ps.series.push_back(s);
                return;
            }
            if (!subset(ve, xy)) throw CasError(QString::fromUtf8("Usa solo x e y (o z para superficies)."));
            s.kind = Series::Implicit;
            s.p.push_back(compileOrThrow(E, xy));
            ps.series.push_back(s);
            return;
        }
        if (!rs.ops.isEmpty()) {
            s.kind = Series::Region;
            for (int i = 0; i < rs.ops.size(); ++i) {
                if (rs.ops[i] == "=") throw CasError(QString::fromUtf8("No mezcles «=» con desigualdades en la misma línea."));
                gen L = user(rs.parts[i]), R = user(rs.parts[i + 1]);
                gen E = ev(giac::symbolic(giac::at_plus, gen(giac::makevecteur(L, -R), giac::_SEQ__VECT)));
                if (!subset(varsOf(E), xy)) throw CasError(QString::fromUtf8("Las regiones se dibujan en x e y."));
                s.p.push_back(compileOrThrow(E, xy));
                s.rel.push_back(relCode(rs.ops[i]));
            }
            ps.series.push_back(s);
            return;
        }
        gen g = user(raw);
        QStringList v = varsOf(g);
        if (v == QStringList{"z"}) {
            s.kind = Series::Domain;
            s.p.push_back(compileOrThrow(g, {"z"}));
            ps.series.push_back(s);
            return;
        }
        if (subset(v, {"x"}) || v.size() == 1) {
            QString var = v.isEmpty() ? "x" : v[0];
            if (var != "x" && var != "y") paramVar = var;
            s.kind = Series::Func;
            s.p.push_back(compileOrThrow(g, {var == "y" ? "y" : var}));
            s.complexParts = hasComplexConst(g);
            ps.series.push_back(s);
            return;
        }
        if (subset(v, xy)) {
            s.kind = Series::Surface;
            s.p.push_back(compileOrThrow(g, xy));
            ps.series.push_back(s);
            return;
        }
        throw CasError(QString::fromUtf8("Demasiadas variables (%1). Usa x, y o un parámetro t.").arg(v.join(", ")));
    }

    void plot(const Request &rq, Response &r)
    {
        auto ps = std::make_shared<PlotSpec>();
        const QVariantMap &pm = rq.params;
        ps->xmin = pm.value("xmin", -10).toDouble();
        ps->xmax = pm.value("xmax", 10).toDouble();
        ps->ymin = pm.contains("ymin") ? pm.value("ymin").toDouble() : NAN;
        ps->ymax = pm.contains("ymax") ? pm.value("ymax").toDouble() : NAN;
        ps->tmin = pm.value("tmin", -10).toDouble();
        ps->tmax = pm.value("tmax", 10).toDouble();
        QStringList errors;
        std::vector<size_t> owner;   // line index of each series
        for (int i = 0; i < rq.lines.size(); ++i) {
            const QString line = rq.lines[i].trimmed();
            QString err;
            if (!line.isEmpty()) {
                size_t before = ps->series.size();
                QString pv;
                try {
                    classify(line, *ps, i, pv);
                } catch (const std::exception &e) {
                    ps->series.resize(before);
                    err = cleanError(QString::fromUtf8(e.what()));
                }
                for (size_t k = before; k < ps->series.size(); ++k) owner.push_back(i);
            }
            errors << err;
        }
        bool has3D = false, has2D = false;
        for (auto &s : ps->series) {
            bool is3 = s.kind == Series::Surface || s.kind == Series::Param3 || s.kind == Series::Implicit3;
            has3D |= is3;
            has2D |= !is3;
        }
        if (has3D && has2D) {
            std::vector<Series> keep;
            for (size_t k = 0; k < ps->series.size(); ++k) {
                auto &s = ps->series[k];
                bool is3 = s.kind == Series::Surface || s.kind == Series::Param3 || s.kind == Series::Implicit3;
                if (is3) keep.push_back(s);
                else errors[int(owner[k])] = QString::fromUtf8("Hay gráficas 3D: esta (2D) no se muestra.");
            }
            ps->series = keep;
        }
        ps->is3D = has3D;
        if (has3D && pm.value("xauto").toBool()) ps->xmin = -5, ps->xmax = 5, ps->ymin = -5, ps->ymax = 5;
        r.itemErrors = errors;
        r.plot = ps;
    }
};

// ===================================================================== Cas
class Cas::Worker : public QThread {
public:
    explicit Worker(Cas *c) : m_cas(c) { setStackSize(256 * 1024 * 1024); }

protected:
    void run() override
    {
        CasEngine eng;
        QStringList defs;
        {
            QMutexLocker l(&m_cas->m_mutex);
            defs = m_cas->m_defs;
        }
        for (auto &d : defs) eng.define(d);
        for (;;) {
            Request rq;
            {
                QMutexLocker l(&m_cas->m_mutex);
                while (m_cas->m_queue.empty() && !m_cas->m_quit) m_cas->m_cond.wait(&m_cas->m_mutex);
                if (m_cas->m_quit) return;
                rq = m_cas->m_queue.front();
                m_cas->m_queue.pop_front();
            }
            Response resp = eng.handle(rq);
            Cas *cas = m_cas;
            QMetaObject::invokeMethod(cas, [cas, resp]() { cas->deliver(resp); }, Qt::QueuedConnection);
        }
    }

private:
    Cas *m_cas;
};

Cas::Cas(QObject *parent) : QObject(parent)
{
    qRegisterMetaType<Response>();
    // Giac formats and parses numbers with the C library; a Spanish locale
    // would turn 0.5 into "0,5" and break round trips.
    setlocale(LC_NUMERIC, "C");
}

Cas::~Cas()
{
    if (m_thread) {
        {
            QMutexLocker l(&m_mutex);
            m_quit = true;
            m_cond.wakeAll();
        }
        giac::ctrl_c = true;
        giac::interrupted = true;
        if (!m_thread->wait(1500)) m_thread->terminate(), m_thread->wait();
        delete m_thread;
    }
}

void Cas::setDefinitions(const QStringList &defs)
{
    m_defs = defs;
    if (!m_thread) {
        m_thread = new Worker(this);
        m_thread->start();
    }
}

int Cas::submit(Request r)
{
    if (!m_thread) setDefinitions(m_defs);
    r.id = m_nextId++;
    {
        QMutexLocker l(&m_mutex);
        if (r.kind == Request::Preview) {
            m_queue.erase(std::remove_if(m_queue.begin(), m_queue.end(), [](const Request &q) { return q.kind == Request::Preview; }),
                          m_queue.end());
        } else if (m_pending++ == 0) {
            emit busyChanged(true);
        }
        m_queue.push_back(r);
        m_cond.wakeOne();
    }
    return r.id;
}

void Cas::cancel()
{
    std::vector<Request> dropped;
    {
        QMutexLocker l(&m_mutex);
        for (auto &q : m_queue)
            if (q.kind != Request::Preview) dropped.push_back(q);
        m_queue.clear();
    }
    giac::ctrl_c = true;
    giac::interrupted = true;
    for (auto &q : dropped) {
        Response r;
        r.id = q.id;
        r.kind = q.kind;
        r.ok = false;
        r.error = QString::fromUtf8("Cálculo cancelado.");
        deliver(r);
    }
}

void Cas::deliver(Response r)
{
    if (r.kind != Request::Preview && --m_pending == 0) emit busyChanged(false);
    if (m_pending < 0) m_pending = 0;
    emit finished(r);
}
