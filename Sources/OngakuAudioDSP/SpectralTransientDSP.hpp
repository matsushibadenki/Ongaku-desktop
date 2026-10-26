#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>

namespace ongaku {
// Causal complementary three-band prototype; no FFT window or lookahead.
// Render owns every filter/envelope/ramp state. Control writes atomics only.
class SpectralTransient {
    static_assert(std::atomic<float>::is_always_lock_free);
    static_assert(std::atomic<bool>::is_always_lock_free);
    std::atomic<float> requested{0};
    std::atomic<bool> resetPending{false};
    std::array<double,8> low{}, upper{};
    std::array<double,2> fast{}, slow{};
    double lowA=0, upperA=0, release=0, slowA=0;
    unsigned channels=0, rampLength=1, remaining=0;
    double amount=0, target=0, step=0;
    void clearHistory() noexcept { low={}; upper={}; fast={}; slow={}; }
public:
    bool prepare(unsigned ch, double rate) noexcept {
        if (ch<1 || ch>8 || !std::isfinite(rate) || rate<8000 || rate>384000) return false;
        channels=ch; lowA=1-std::exp(-2*3.141592653589793*250/rate);
        upperA=1-std::exp(-2*3.141592653589793*std::min(4000.,rate*.35)/rate);
        release=std::exp(-1/(rate*.008)); slowA=1-std::exp(-1/(rate*.050));
        rampLength=std::max(1u,unsigned(rate*.020));
        clearHistory(); amount=target=step=0; remaining=0;
        resetPending.store(false,std::memory_order_relaxed);
        return true;
    }
    void setAmount(float value) noexcept {
        requested.store(std::isfinite(value)?std::clamp(value,0.f,1.f):0.f,std::memory_order_release);
    }
    void requestReset() noexcept { resetPending.store(true,std::memory_order_release); }
    void process(const float *const *in, float *const *out, unsigned frames) noexcept {
        if (resetPending.exchange(false,std::memory_order_acq_rel)) clearHistory();
        const double next=requested.load(std::memory_order_acquire);
        if (next!=target) { target=next; remaining=rampLength; step=(target-amount)/rampLength; }
        for (unsigned i=0;i<frames;++i) {
            if (remaining) { amount+=step; if (!--remaining) amount=target; }
            std::array<double,8> x{}, mid{}, high{};
            double midPeak=0, highPeak=0;
            for (unsigned ch=0;ch<channels;++ch) {
                x[ch]=std::isfinite(in[ch][i])?in[ch][i]:0;
                low[ch]+=lowA*(x[ch]-low[ch]); upper[ch]+=upperA*(x[ch]-upper[ch]);
                if (std::abs(low[ch])<1e-20) low[ch]=0;
                if (std::abs(upper[ch])<1e-20) upper[ch]=0;
                mid[ch]=upper[ch]-low[ch]; high[ch]=x[ch]-upper[ch];
                midPeak=std::max(midPeak,std::abs(mid[ch])); highPeak=std::max(highPeak,std::abs(high[ch]));
            }
            std::array<double,2> transient{};
            for (unsigned band=0;band<2;++band) {
                const double peak=band?highPeak:midPeak;
                fast[band]=std::max(peak,fast[band]*release);
                // Compare peak-held envelopes at two time scales, not peak vs
                // mean-absolute level (which would boost steady sine waves).
                slow[band]+=slowA*(fast[band]-slow[band]);
                if (fast[band]<1e-20) fast[band]=0;
                if (std::abs(slow[band])<1e-20) slow[band]=0;
                transient[band]=std::clamp((fast[band]-slow[band])/(fast[band]+1e-12),0.,1.)*std::min(1.,fast[band]/.01);
            }
            for (unsigned ch=0;ch<channels;++ch) {
                const double y=x[ch]+amount*(.05*transient[0]*mid[ch]+.03*transient[1]*high[ch]);
                out[ch][i]=amount==0?float(x[ch]):(std::isfinite(float(y))?float(y):0.f);
            }
        }
    }
};
}
