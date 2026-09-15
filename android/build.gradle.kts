import com.android.build.api.dsl.LibraryExtension
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension

allprojects {
    repositories {
        google()
        mavenCentral()
        maven(url = "https://jitpack.io")
    }
}

// 仅为主项目设置构建目录，避免跨驱动器问题
subprojects {
    // 只为 app 模块设置自定义构建目录
    if (project.name == "app") {
        val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build/app").get()
        project.layout.buildDirectory.value(newBuildDir)
    }
    // 其他子项目（包括插件）使用默认构建目录
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Configure Java version for all subprojects
subprojects {
    plugins.withType<JavaPlugin> {
        configure<JavaPluginExtension> {
            sourceCompatibility = JavaVersion.VERSION_17
            targetCompatibility = JavaVersion.VERSION_17
        }
    }

    pluginManager.withPlugin("org.jetbrains.kotlin.android") {
        extensions.configure<KotlinAndroidProjectExtension> {
            compilerOptions {
                jvmTarget = JvmTarget.JVM_17
            }
        }
    }

    if (project.name == "file_picker") {
        pluginManager.withPlugin("com.android.library") {
            pluginManager.apply("org.jetbrains.kotlin.android")
        }
    }

    if (project.name == "flutter_js") {
        pluginManager.withPlugin("com.android.library") {
            extensions.configure<LibraryExtension> {
                compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_1_8
                    targetCompatibility = JavaVersion.VERSION_1_8
                }
            }
        }
    }

}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
