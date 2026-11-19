import Foundation
import Testing

@Suite("短视频自动画中画偏好")
struct DYAutoPiPTests {
    @Test func missingKeyIsOff() {
        let defaults = UserDefaults(suiteName: "DYAutoPiPTests.missing")!
        defaults.removePersistentDomain(forName: "DYAutoPiPTests.missing")
        #expect(DYAutoPiP.enabled(in: defaults) == false)
    }

    @Test func shortVideoStaysEligibleInCleanScreenWhenPreferenceIsOff() {
        #expect(DYAutoPiP.shortVideoWantsAutomaticPiP(preference: false, cleanScreen: true, isActive: true))
        #expect(DYAutoPiP.shortVideoWantsAutomaticPiP(preference: false, cleanScreen: false, isActive: true) == false)
    }

    @Test func preferenceExtendsEligibilityToOrdinaryPlayback() {
        #expect(DYAutoPiP.shortVideoWantsAutomaticPiP(preference: true, cleanScreen: false, isActive: true))
        #expect(DYAutoPiP.shortVideoWantsAutomaticPiP(preference: true, cleanScreen: false, isActive: false) == false)
    }

    @Test func inactivePageNeverWantsPiP() {
        #expect(DYAutoPiP.shortVideoWantsAutomaticPiP(preference: true, cleanScreen: true, isActive: false) == false)
    }

    @Test func turningThePreferenceOffDropsTheIdleController() {
        #expect(DYAutoPiP.keepsPiPController(enabled: false, active: false, starting: false) == false)
        #expect(DYAutoPiP.keepsPiPController(enabled: true, active: false, starting: false))
    }

    @Test func turningThePreferenceOffKeepsAWindowThatIsAlreadyOpenUntilItStops() {
        #expect(DYAutoPiP.keepsPiPController(enabled: false, active: true, starting: false))
        #expect(DYAutoPiP.keepsPiPController(enabled: false, active: false, starting: true))
    }

    @Test func preferencePersistsAcrossDefaultsInstances() {
        let suite = "DYAutoPiPTests.persistence"
        let first = UserDefaults(suiteName: suite)!
        defer { first.removePersistentDomain(forName: suite) }
        first.removePersistentDomain(forName: suite)
        first.set(true, forKey: DYAutoPiP.storageKey)
        #expect(DYAutoPiP.enabled(in: UserDefaults(suiteName: suite)!))
        first.set(false, forKey: DYAutoPiP.storageKey)
        #expect(!DYAutoPiP.enabled(in: UserDefaults(suiteName: suite)!))
    }
    @Test func piPUsesNativeAudioEvenAfterChangingSpeed() {
        #expect(DYAutoPiP.requiresNativeAudio(preference: true, cleanScreen: false))
        #expect(DYAutoPiP.requiresNativeAudio(preference: false, cleanScreen: true))
        #expect(DYAutoPiP.requiresNativeAudio(preference: true, cleanScreen: true))
        #expect(!DYAutoPiP.requiresNativeAudio(preference: false, cleanScreen: false))
    }
}
