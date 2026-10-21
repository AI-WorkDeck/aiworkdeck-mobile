export const start: (fd: number) => boolean;
/** Accepted PCM is also classified. -1: detector unavailable; -2: recording failed. */
export const push: (pcm: ArrayBuffer) => number;
export const resetVoice: () => void;
export const finish: () => Promise<boolean>;
