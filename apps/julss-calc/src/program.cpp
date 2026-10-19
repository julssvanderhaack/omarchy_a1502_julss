// Formula-node helpers and the numeric bytecode interpreter.
#include "types.h"
#include <QJsonArray>

namespace M {
static MPtr make(MNode::Kind k, const QString &t = {}, std::vector<MPtr> c = {}, int n = 0)
{
    auto m = std::make_shared<MNode>();
    m->kind = k;
    m->text = t;
    m->c = std::move(c);
    m->n = n;
    return m;
}
MPtr row(std::vector<MPtr> c)
{
    if (c.size() == 1 && c[0]) return c[0];
    return make(MNode::Row, {}, std::move(c));
}
MPtr num(const QString &s) { return make(MNode::Num, s); }
MPtr var(const QString &s) { return make(MNode::Var, s); }
MPtr op(const QString &s) { return make(MNode::Op, s); }
MPtr text(const QString &s) { return make(MNode::Text, s); }
MPtr frac(MPtr a, MPtr b) { return make(MNode::Frac, {}, {a, b}); }
MPtr pow(MPtr a, MPtr b) { return make(MNode::Pow, {}, {a, b}); }
MPtr sub(MPtr a, MPtr b) { return make(MNode::Sub, {}, {a, b}); }
MPtr sqrt(MPtr a, MPtr idx) { return make(MNode::Sqrt, {}, {a, idx}); }
MPtr paren(MPtr a, const QString &kind) { return make(MNode::Paren, kind, {a}); }
MPtr conj(MPtr a) { return make(MNode::Conj, {}, {a}); }
MPtr matrix(int cols, std::vector<MPtr> cells) { return make(MNode::Matrix, {}, std::move(cells), cols); }
MPtr bigop(const QString &sym, MPtr body, MPtr lo, MPtr hi) { return make(MNode::BigOp, sym, {body, lo, hi}); }
MPtr under(MPtr a, MPtr b) { return make(MNode::Under, {}, {a, b}); }
MPtr space(int e) { return make(MNode::Space, {}, {}, e); }

QJsonValue toJson(const MPtr &n)
{
    if (!n) return QJsonValue();
    QJsonArray a;
    a.append(int(n->kind));
    a.append(n->text);
    a.append(n->n);
    QJsonArray kids;
    for (auto &c : n->c) kids.append(toJson(c));
    a.append(kids);
    return a;
}

MPtr fromJson(const QJsonValue &v)
{
    if (!v.isArray()) return nullptr;
    auto a = v.toArray();
    if (a.size() < 4) return nullptr;
    std::vector<MPtr> kids;
    for (auto c : a[3].toArray()) kids.push_back(fromJson(c));
    return make(MNode::Kind(a[0].toInt()), a[1].toString(), std::move(kids), a[2].toInt());
}
}

// ------------------------------------------------------------ interpreter
namespace {
inline double sgn(double x) { return (x > 0) - (x < 0); }

// Real cube/odd roots keep negative bases real (x^(1/3) of -8 is -2).
inline double rootOdd(double x, double p, double q)
{
    double r = std::pow(std::fabs(x), p / q);
    bool neg = x < 0 && (long long)std::fabs(p) % 2 == 1;
    return neg ? -r : r;
}

using C = std::complex<double>;
inline C cgamma(C z)
{
    if (z.imag() == 0) return std::tgamma(z.real());
    // Lanczos approximation
    static const double g = 7, coef[] = {0.99999999999980993, 676.5203681218851, -1259.1392167224028,
                                         771.32342877765313, -176.61502916214059, 12.507343278686905,
                                         -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7};
    if (z.real() < 0.5) return M_PI / (std::sin(M_PI * z) * cgamma(1.0 - z));
    z -= 1;
    C x = coef[0];
    for (int i = 1; i < 9; ++i) x += coef[i] / (z + double(i));
    C t = z + g + 0.5;
    return std::sqrt(2 * M_PI) * std::pow(t, z + 0.5) * std::exp(-t) * x;
}
}

double Program::eval(const double *v) const
{
    double st[96];
    int sp = 0;
    for (const Ins &i : code) {
        switch (i.op) {
        case Const: st[sp++] = consts[i.a].imag() == 0 ? consts[i.a].real() : NAN; break;
        case Var: st[sp++] = v[i.a]; break;
        case Add: --sp; st[sp - 1] += st[sp]; break;
        case Sub: --sp; st[sp - 1] -= st[sp]; break;
        case Mul: --sp; st[sp - 1] *= st[sp]; break;
        case Div: --sp; st[sp - 1] /= st[sp]; break;
        case Neg: st[sp - 1] = -st[sp - 1]; break;
        case Pow: --sp; st[sp - 1] = std::pow(st[sp - 1], st[sp]); break;
        case PowInt: {
            double b = st[sp - 1], r = 1;
            long n = std::labs(long(i.a));
            while (n) { if (n & 1) r *= b; b *= b; n >>= 1; }
            st[sp - 1] = i.a < 0 ? 1 / r : r;
            break;
        }
        case RootOdd: st[sp - 1] = rootOdd(st[sp - 1], i.p, i.q); break;
        case Sin: st[sp - 1] = std::sin(st[sp - 1]); break;
        case Cos: st[sp - 1] = std::cos(st[sp - 1]); break;
        case Tan: st[sp - 1] = std::tan(st[sp - 1]); break;
        case Asin: st[sp - 1] = std::asin(st[sp - 1]); break;
        case Acos: st[sp - 1] = std::acos(st[sp - 1]); break;
        case Atan: st[sp - 1] = std::atan(st[sp - 1]); break;
        case Sinh: st[sp - 1] = std::sinh(st[sp - 1]); break;
        case Cosh: st[sp - 1] = std::cosh(st[sp - 1]); break;
        case Tanh: st[sp - 1] = std::tanh(st[sp - 1]); break;
        case Asinh: st[sp - 1] = std::asinh(st[sp - 1]); break;
        case Acosh: st[sp - 1] = std::acosh(st[sp - 1]); break;
        case Atanh: st[sp - 1] = std::atanh(st[sp - 1]); break;
        case Sec: st[sp - 1] = 1 / std::cos(st[sp - 1]); break;
        case Csc: st[sp - 1] = 1 / std::sin(st[sp - 1]); break;
        case Cot: st[sp - 1] = 1 / std::tan(st[sp - 1]); break;
        case Exp: st[sp - 1] = std::exp(st[sp - 1]); break;
        case Ln: st[sp - 1] = st[sp - 1] < 0 ? NAN : std::log(st[sp - 1]); break;
        case Log10: st[sp - 1] = st[sp - 1] < 0 ? NAN : std::log10(st[sp - 1]); break;
        case Sqrt: st[sp - 1] = std::sqrt(st[sp - 1]); break;
        case Abs: st[sp - 1] = std::fabs(st[sp - 1]); break;
        case Sign: st[sp - 1] = sgn(st[sp - 1]); break;
        case Floor: st[sp - 1] = std::floor(st[sp - 1]); break;
        case Ceil: st[sp - 1] = std::ceil(st[sp - 1]); break;
        case Round: st[sp - 1] = std::round(st[sp - 1]); break;
        case Re: break;
        case Im: st[sp - 1] = 0; break;
        case Arg: st[sp - 1] = st[sp - 1] < 0 ? M_PI : 0; break;
        case Conj: break;
        case Erf: st[sp - 1] = std::erf(st[sp - 1]); break;
        case Gamma: st[sp - 1] = std::tgamma(st[sp - 1]); break;
        case Min: --sp; st[sp - 1] = std::fmin(st[sp - 1], st[sp]); break;
        case Max: --sp; st[sp - 1] = std::fmax(st[sp - 1], st[sp]); break;
        case Atan2: --sp; st[sp - 1] = std::atan2(st[sp - 1], st[sp]); break;
        case Heaviside: st[sp - 1] = st[sp - 1] >= 0 ? 1 : 0; break;
        case Lt: --sp; st[sp - 1] = st[sp - 1] < st[sp]; break;
        case Le: --sp; st[sp - 1] = st[sp - 1] <= st[sp]; break;
        case Gt: --sp; st[sp - 1] = st[sp - 1] > st[sp]; break;
        case Ge: --sp; st[sp - 1] = st[sp - 1] >= st[sp]; break;
        case Eq: --sp; st[sp - 1] = st[sp - 1] == st[sp]; break;
        case Ne: --sp; st[sp - 1] = st[sp - 1] != st[sp]; break;
        case And: --sp; st[sp - 1] = (st[sp - 1] != 0) && (st[sp] != 0); break;
        case Or: --sp; st[sp - 1] = (st[sp - 1] != 0) || (st[sp] != 0); break;
        case Ifte: sp -= 2; st[sp - 1] = st[sp - 1] != 0 ? st[sp] : st[sp + 1]; break;
        }
    }
    return sp == 1 ? st[0] : NAN;
}

std::complex<double> Program::evalc(const std::complex<double> *v) const
{
    C st[96];
    int sp = 0;
    const C nan(NAN, NAN);
    for (const Ins &i : code) {
        switch (i.op) {
        case Const: st[sp++] = consts[i.a]; break;
        case Var: st[sp++] = v[i.a]; break;
        case Add: --sp; st[sp - 1] += st[sp]; break;
        case Sub: --sp; st[sp - 1] -= st[sp]; break;
        case Mul: --sp; st[sp - 1] *= st[sp]; break;
        case Div: --sp; st[sp - 1] /= st[sp]; break;
        case Neg: st[sp - 1] = -st[sp - 1]; break;
        case Pow: --sp; st[sp - 1] = std::pow(st[sp - 1], st[sp]); break;
        case PowInt: {
            C b = st[sp - 1], r = 1;
            long n = std::labs(long(i.a));
            while (n) { if (n & 1) r *= b; b *= b; n >>= 1; }
            st[sp - 1] = i.a < 0 ? 1.0 / r : r;
            break;
        }
        case RootOdd:
            if (st[sp - 1].imag() == 0) st[sp - 1] = rootOdd(st[sp - 1].real(), i.p, i.q);
            else st[sp - 1] = std::pow(st[sp - 1], i.p / i.q);
            break;
        case Sin: st[sp - 1] = std::sin(st[sp - 1]); break;
        case Cos: st[sp - 1] = std::cos(st[sp - 1]); break;
        case Tan: st[sp - 1] = std::tan(st[sp - 1]); break;
        case Asin: st[sp - 1] = std::asin(st[sp - 1]); break;
        case Acos: st[sp - 1] = std::acos(st[sp - 1]); break;
        case Atan: st[sp - 1] = std::atan(st[sp - 1]); break;
        case Sinh: st[sp - 1] = std::sinh(st[sp - 1]); break;
        case Cosh: st[sp - 1] = std::cosh(st[sp - 1]); break;
        case Tanh: st[sp - 1] = std::tanh(st[sp - 1]); break;
        case Asinh: st[sp - 1] = std::asinh(st[sp - 1]); break;
        case Acosh: st[sp - 1] = std::acosh(st[sp - 1]); break;
        case Atanh: st[sp - 1] = std::atanh(st[sp - 1]); break;
        case Sec: st[sp - 1] = 1.0 / std::cos(st[sp - 1]); break;
        case Csc: st[sp - 1] = 1.0 / std::sin(st[sp - 1]); break;
        case Cot: st[sp - 1] = 1.0 / std::tan(st[sp - 1]); break;
        case Exp: st[sp - 1] = std::exp(st[sp - 1]); break;
        case Ln: st[sp - 1] = std::log(st[sp - 1]); break;
        case Log10: st[sp - 1] = std::log10(st[sp - 1]); break;
        case Sqrt: st[sp - 1] = std::sqrt(st[sp - 1]); break;
        case Abs: st[sp - 1] = std::abs(st[sp - 1]); break;
        case Sign: { double a = std::abs(st[sp - 1]); st[sp - 1] = a == 0 ? C(0) : st[sp - 1] / a; break; }
        case Floor: st[sp - 1] = C(std::floor(st[sp - 1].real()), std::floor(st[sp - 1].imag())); break;
        case Ceil: st[sp - 1] = C(std::ceil(st[sp - 1].real()), std::ceil(st[sp - 1].imag())); break;
        case Round: st[sp - 1] = C(std::round(st[sp - 1].real()), std::round(st[sp - 1].imag())); break;
        case Re: st[sp - 1] = st[sp - 1].real(); break;
        case Im: st[sp - 1] = st[sp - 1].imag(); break;
        case Arg: st[sp - 1] = std::arg(st[sp - 1]); break;
        case Conj: st[sp - 1] = std::conj(st[sp - 1]); break;
        case Erf: st[sp - 1] = st[sp - 1].imag() == 0 ? C(std::erf(st[sp - 1].real())) : nan; break;
        case Gamma: st[sp - 1] = cgamma(st[sp - 1]); break;
        case Min: --sp; st[sp - 1] = std::fmin(st[sp - 1].real(), st[sp].real()); break;
        case Max: --sp; st[sp - 1] = std::fmax(st[sp - 1].real(), st[sp].real()); break;
        case Atan2: --sp; st[sp - 1] = std::atan2(st[sp - 1].real(), st[sp].real()); break;
        case Heaviside: st[sp - 1] = st[sp - 1].real() >= 0 ? 1 : 0; break;
        case Lt: --sp; st[sp - 1] = st[sp - 1].real() < st[sp].real(); break;
        case Le: --sp; st[sp - 1] = st[sp - 1].real() <= st[sp].real(); break;
        case Gt: --sp; st[sp - 1] = st[sp - 1].real() > st[sp].real(); break;
        case Ge: --sp; st[sp - 1] = st[sp - 1].real() >= st[sp].real(); break;
        case Eq: --sp; st[sp - 1] = st[sp - 1] == st[sp]; break;
        case Ne: --sp; st[sp - 1] = st[sp - 1] != st[sp]; break;
        case And: --sp; st[sp - 1] = (st[sp - 1] != C(0)) && (st[sp] != C(0)); break;
        case Or: --sp; st[sp - 1] = (st[sp - 1] != C(0)) || (st[sp] != C(0)); break;
        case Ifte: sp -= 2; st[sp - 1] = st[sp - 1] != C(0) ? st[sp] : st[sp + 1]; break;
        }
    }
    return sp == 1 ? st[0] : nan;
}
