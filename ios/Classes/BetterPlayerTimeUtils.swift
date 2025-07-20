import AVFoundation

/// A utility class for time-related conversions, structured as a non-instantiable enum
/// to act as a pure namespace for static methods.
public enum BetterPlayerTimeUtils {

    /// Converts a CMTime object to milliseconds (Int64).
    ///
    /// - Parameter time: The CMTime to convert.
    /// - Returns: The equivalent value in milliseconds, or 0 if the timescale is invalid.
    public static func fltCMTimeToMillis(_ time: CMTime) -> Int64 {
        // A timescale of 0 is invalid and would lead to a division by zero.
        guard time.timescale != 0 else {
            return 0
        }
        return Int64(time.value) * 1000 / Int64(time.timescale)
    }

    /// Converts a TimeInterval (NSTimeInterval) object to milliseconds (Int64).
    ///
    /// - Parameter interval: The TimeInterval to convert.
    /// - Returns: The equivalent value in milliseconds.
    public static func fltNSTimeIntervalToMillis(_ interval: TimeInterval) -> Int64 {
        return Int64(interval * 1000.0)
    }
}