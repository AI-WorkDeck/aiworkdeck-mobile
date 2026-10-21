#pragma once

// EOS is an independent flag: the same output buffer may contain the final audio payload.
// Drain that payload before acknowledging EOS, including when the writer reports a failure.
template<class Write, class End>
bool consumeEncodedPacket(int size, bool codecData, bool eos, Write write, End end) {
    bool ok = true;
    if (size > 0 && !codecData) ok = write();
    if (eos) end();
    return ok;
}
