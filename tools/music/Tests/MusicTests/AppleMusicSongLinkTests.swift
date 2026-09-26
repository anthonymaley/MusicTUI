// tools/music/Tests/MusicTests/AppleMusicSongLinkTests.swift
//
// `appleMusicSongID(from:)`, the one parser both `music play` bodies (Music.app
// and Bridge) use to recognise a song link. Pure string parsing: no playback,
// no network, no config.
import XCTest
@testable import music

final class AppleMusicSongLinkTests: XCTestCase {

    func testTheAlbumQueryFormIsUnchanged() {
        XCTAssertEqual(appleMusicSongID(from: "https://music.apple.com/us/album/mezzanine/1440857000?i=1440857781"), "1440857781")
    }

    func testTheSongPathFormWithASlug() {
        XCTAssertEqual(appleMusicSongID(from: "https://music.apple.com/us/song/teardrop/1440857781"), "1440857781")
        XCTAssertEqual(appleMusicSongID(from: "https://music.apple.com/gb/song/teardrop-remastered-2019/1440857781"), "1440857781")
    }

    func testTheSongPathFormWithoutASlug() {
        XCTAssertEqual(appleMusicSongID(from: "https://music.apple.com/us/song/1440857781"), "1440857781")
    }

    func testTheSongPathFormIgnoresItsQueryStringAndFragment() {
        XCTAssertEqual(appleMusicSongID(from: "https://music.apple.com/us/song/teardrop/1440857781?ls=1&app=music"), "1440857781")
        XCTAssertEqual(appleMusicSongID(from: "https://music.apple.com/us/song/teardrop/1440857781#x"), "1440857781")
    }

    func testTheSongPathFormAcceptsAnyTwoLetterStorefrontAndDoubledSlashes() {
        XCTAssertEqual(appleMusicSongID(from: "https://music.apple.com/IE/song/teardrop/1440857781"), "1440857781")
        XCTAssertEqual(appleMusicSongID(from: "https://music.apple.com//us//song/teardrop//1440857781/"), "1440857781")
    }

    func testAMalformedSongPathIsRefusedNotGuessed() {
        for link in ["https://music.apple.com/us/song/teardrop/14408x57781",
                     "https://music.apple.com/us/song/teardrop/",
                     "https://music.apple.com/us/song/teardrop",
                     "https://music.apple.com/us/song/a/b/1440857781",
                     "https://music.apple.com/usa/song/teardrop/1440857781",
                     "https://music.apple.com/song/teardrop/1440857781",
                     "https://music.apple.com/us/song/teardrop/-1440857781",
                     "https://music.apple.com/us/song/teardrop/\u{FF11}\u{FF12}\u{FF13}",
                     "https://evil.example/music.apple.com/us/song/teardrop/1440857781",
                     "music.apple.com/us/song/teardrop/1440857781"] {
            XCTAssertNil(appleMusicSongID(from: link), link)
        }
    }

    func testOtherLinkKindsStillDoNotMatch() {
        for link in ["https://music.apple.com/us/album/mezzanine/1440857000",
                     "https://music.apple.com/us/playlist/todays-hits/pl.f4d106fed2bd41149aaacabb233eb5eb",
                     "https://music.apple.com/us/artist/massive-attack/2587",
                     "https://music.apple.com/us/station/apple-music-1/ra.978194965",
                     "https://music.apple.com/us/music-video/teardrop/1440857781"] {
            XCTAssertNil(appleMusicSongID(from: link), link)
        }
    }
}
