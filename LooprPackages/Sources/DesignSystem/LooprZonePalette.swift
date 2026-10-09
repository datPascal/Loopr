/// The same five effort colours wherever Loopr shows heart-rate zones.
public enum LooprZonePalette {
    public static func token(for number: Int) -> LooprColorToken {
        switch number {
        case 1: .sleepSweep
        case 2: .brand
        case 3: .strain
        case 4: .strainSweep
        case 5: .heart
        default: .ink
        }
    }

    public static func textToken(for number: Int) -> LooprColorToken {
        switch number {
        case 1: .sleepSweep
        case 2: .brandInk
        case 3: .strain
        case 4: .strainSweep
        case 5: .heartChip
        default: .ink
        }
    }
}
