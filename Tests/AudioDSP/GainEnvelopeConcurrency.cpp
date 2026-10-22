#include "GainEnvelopeDSP.hpp"
#include <thread>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <limits>
static void check(bool value, const char *message) {
    if (!value) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}
int main() {
    ongaku::GainEnvelope gain;
    gain.resetMuted();
    for (float bad : {-3.f, 2.f, std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity()}) {
        auto token = gain.ramp(bad, 0); gain.begin();
        const float result = gain.next();
        check(result >= 0 && result <= 1 && std::isfinite(result), "invalid gain escaped attenuation range");
        check(gain.isComplete(token), "immediate command completion");
    }
    std::atomic<bool> done{false}, failed{false};
    std::thread writer([&] {
        for (unsigned i = 0; i < 30000; ++i) gain.ramp(float(i % 101) / 100, i % 3000);
        done.store(true);
    });
    uint64_t blocks = 0;
    while (!done.load() || blocks < 10000) {
        gain.begin();
        for (unsigned frame = 0; frame < 127; ++frame) {
            float value = gain.next();
            if (!std::isfinite(value) || value < 0 || value > 1) failed.store(true);
        }
        ++blocks;
    }
    writer.join();
    check(!failed.load(), "concurrent publication corrupted gain");
    auto final = gain.ramp(0, 257); gain.begin();
    for (unsigned i = 0; i < 256; ++i) gain.next();
    check(!gain.isComplete(final), "early completion");
    check(gain.next() == 0 && gain.isComplete(final), "final mute did not settle");
    gain.resetMuted();
    check(!gain.isComplete(final), "reset reused old completion identity");
    printf("PASS: 30000 concurrent commands / %llu render blocks, finite bounded gain, exact final mute and lifecycle identity\n", (unsigned long long)blocks);
}
