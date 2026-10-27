/*
 * Copyright (C) 2026 PNT Apps. Part of Veltoret, licensed under the GNU GPL v3 (see LICENSE and NOTICE).
 */
package androidx.media3.extractor.mkv;

import androidx.media3.common.C;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.common.util.Util;
import androidx.media3.extractor.BinarySearchSeeker;
import androidx.media3.extractor.ExtractorInput;
import java.io.IOException;

/**
 * Veltoret: seeks in Matroska files that have no Cues (index) by binary-searching Cluster timecodes,
 * the way VLC and FFmpeg do. Upstream Media3 treats such files as unseekable, so every seek played
 * on from where it was.
 *
 * <p>Each probe reads ahead from a byte position to the next Cluster and compares its Timecode with
 * the target. Positions handed back are always the start of a Cluster, so the extractor can carry on
 * parsing from there.
 */
@UnstableApi
final class VeltoretMatroskaClusterSeeker extends BinarySearchSeeker {

  /** Pull the guesses a little earlier so the probe usually lands just before the target. */
  private static final long GUESS_BIAS_BYTES = 256 * 1024;
  /** Once floor and ceiling are this close, read forward from the floor instead of probing again. */
  private static final int MINIMUM_SEARCH_RANGE_BYTES = 2 * 1024 * 1024;

  VeltoretMatroskaClusterSeeker(
      long timecodeScale, long durationUs, long firstClusterPosition, long endPosition) {
    super(
        new DefaultSeekTimestampConverter(),
        new ClusterTimestampSeeker(timecodeScale, durationUs),
        durationUs,
        /* floorTimePosition= */ 0,
        /* ceilingTimePosition= */ durationUs + 1,
        /* floorBytePosition= */ firstClusterPosition,
        /* ceilingBytePosition= */ endPosition,
        /* approxBytesPerFrame= */ GUESS_BIAS_BYTES,
        MINIMUM_SEARCH_RANGE_BYTES);
  }

  private static final class ClusterTimestampSeeker implements TimestampSeeker {

    private static final int ID_CLUSTER = 0x1F43B675;
    private static final int ID_TIMECODE = 0xE7;
    private static final int ID_CRC32 = 0xBF;
    /** How far a probe reads looking for a Cluster before giving up. */
    private static final int SEARCH_BYTES = 8 * 1024 * 1024;
    private static final int CHUNK_BYTES = 64 * 1024;
    /** Longest Cluster header we accept: ID, size, optional CRC-32, Timecode ID, size, value. */
    private static final int MAX_HEADER_BYTES = 4 + 8 + 6 + 1 + 8 + 8;
    /** A Cluster starting this soon before the target is close enough: playback reads on from it. */
    private static final long TARGET_TOLERANCE_US = 5_000_000;

    private final long timecodeScale;
    private final long durationUs;
    private final byte[] chunk = new byte[CHUNK_BYTES];
    private final byte[] header = new byte[MAX_HEADER_BYTES];
    private long lastFloorPosition = C.INDEX_UNSET;

    ClusterTimestampSeeker(long timecodeScale, long durationUs) {
      this.timecodeScale = timecodeScale;
      this.durationUs = durationUs;
    }

    @Override
    public TimestampSearchResult searchForTimestamp(ExtractorInput input, long targetTimeUs)
        throws IOException {
      long searchStart = input.getPosition();
      int scanned = 0;
      while (scanned < SEARCH_BYTES) {
        input.resetPeekPosition();
        input.advancePeekPosition(scanned);
        int read = peekUpTo(input, chunk, CHUNK_BYTES);
        if (read < 4) {
          break;
        }
        for (int i = 0; i + 4 <= read; i++) {
          if (chunk[i] != 0x1F
              || chunk[i + 1] != 0x43
              || chunk[i + 2] != (byte) 0xB6
              || chunk[i + 3] != 0x75) {
            continue;
          }
          long timeUs = readClusterTimeUs(input, scanned + i);
          if (timeUs == C.TIME_UNSET) {
            continue;
          }
          long clusterPosition = searchStart + scanned + i;
          if (timeUs > targetTimeUs) {
            // Every position between the search start and this Cluster belongs to an earlier
            // Cluster, so the search start itself is a safe new ceiling.
            return TimestampSearchResult.overestimatedResult(timeUs, searchStart);
          }
          if (targetTimeUs - timeUs <= TARGET_TOLERANCE_US || clusterPosition == lastFloorPosition) {
            // Close enough, or the search keeps coming back to this Cluster: read on from it.
            return TimestampSearchResult.targetFoundResult(clusterPosition);
          }
          lastFloorPosition = clusterPosition;
          return TimestampSearchResult.underestimatedResult(timeUs, clusterPosition);
        }
        // Step back a little so a Cluster ID split across two chunks is still seen.
        scanned += read - 3;
        if (read < CHUNK_BYTES) {
          break;
        }
      }
      return TimestampSearchResult.NO_TIMESTAMP_IN_RANGE_RESULT;
    }

    @Override
    public void onSeekFinished() {
      lastFloorPosition = C.INDEX_UNSET;
    }

    /**
     * Returns the time of the Cluster whose ID starts {@code offset} bytes past the input position,
     * or {@link C#TIME_UNSET} if the bytes there don't look like a Cluster header after all.
     */
    private long readClusterTimeUs(ExtractorInput input, int offset) throws IOException {
      input.resetPeekPosition();
      input.advancePeekPosition(offset);
      int length = peekUpTo(input, header, MAX_HEADER_BYTES);
      int pos = 4;
      if (pos >= length) {
        return C.TIME_UNSET;
      }
      int sizeLength = varintLength(header[pos]);
      if (sizeLength == 0) {
        return C.TIME_UNSET;
      }
      pos += sizeLength;
      if (pos + 2 <= length && (header[pos] & 0xFF) == ID_CRC32 && (header[pos + 1] & 0xFF) == 0x84) {
        pos += 6;
      }
      if (pos + 2 > length || (header[pos] & 0xFF) != ID_TIMECODE) {
        return C.TIME_UNSET;
      }
      int valueSizeLength = varintLength(header[pos + 1]);
      if (valueSizeLength != 1) {
        return C.TIME_UNSET;
      }
      int valueSize = header[pos + 1] & 0x7F;
      pos += 2;
      if (valueSize < 1 || valueSize > 8 || pos + valueSize > length) {
        return C.TIME_UNSET;
      }
      long timecode = 0;
      for (int i = 0; i < valueSize; i++) {
        timecode = (timecode << 8) | (header[pos + i] & 0xFF);
      }
      if (timecode < 0) {
        return C.TIME_UNSET;
      }
      long timeUs = Util.scaleLargeTimestamp(timecode, timecodeScale, 1000);
      // A real Cluster lies within the movie; anything wildly past the end is a false match.
      return timeUs <= durationUs + 60_000_000L ? timeUs : C.TIME_UNSET;
    }

    /** The length in bytes of an EBML varint starting with {@code firstByte}, or 0 if invalid. */
    private static int varintLength(byte firstByte) {
      int b = firstByte & 0xFF;
      return b == 0 ? 0 : Integer.numberOfLeadingZeros(b) - 23;
    }

    /** Peeks up to {@code length} bytes, fewer at the end of the input. */
    private static int peekUpTo(ExtractorInput input, byte[] target, int length) throws IOException {
      int total = 0;
      while (total < length) {
        int read = input.peek(target, total, length - total);
        if (read == C.RESULT_END_OF_INPUT) {
          break;
        }
        total += read;
      }
      return total;
    }
  }
}
