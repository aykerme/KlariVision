plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.aykerme.klarivision.core"
    compileSdk = 35
    ndkVersion = "27.3.13750724"

    defaultConfig {
        minSdk = 26
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk {
            // docs/ANDROID_FEASIBILITY.md: ilk ürün yalnız arm64-v8a paketler.
            abiFilters += "arm64-v8a"
        }
        externalNativeBuild {
            cmake {
                // DSP çekirdeği debug varyantında da optimize edilir.
                // NDK debug varsayılanı -O0'dır ve pitch motoru o hâlde
                // gerçek zamanın ~8 katı yavaş çalışır (ölçüldü), yani
                // optimizasyonsuz bir derlemeyle canlı yol hiç sınanamaz.
                // Hata ayıklama sembolleri RelWithDebInfo ile korunur.
                arguments += listOf(
                    "-DANDROID_STL=c++_shared",
                    "-DCMAKE_BUILD_TYPE=RelWithDebInfo",
                )
                cppFlags += "-std=c++20"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.31.6"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
