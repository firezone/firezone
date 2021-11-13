const {series, src, dest} = require('gulp')
const rename = require('gulp-rename')
const sass = require('gulp-sass')
const babel = require('gulp-babel')
const uglify = require('gulp-uglify')

sass.compiler = require('node-sass')

/* Destination dir */

const destDir = './demo'

/* JS. Transpile with babel & minify */

const processJs = (baseName, isMin) => {
  let r = src('src/js/' + baseName + '.js')
    .pipe(babel({
      presets: ['@babel/env']
    }))

  if (isMin) {
    r = r.pipe(uglify()).pipe(rename(baseName + '.min.js'))
  }

  return r.pipe(dest(destDir + '/js'))
}

const processJsMain = () => {
  return processJs('main')
}

const processJsMainMin = () => {
  return processJs('main', true)
}

const processJsChartSample = () => {
  return processJs('chart.sample')
}

const processJsChartSampleMin = () => {
  return processJs('chart.sample', true)
}

/* SCSS */

const processScss = (baseName, isMin) => {
  const outputStyle = isMin ? 'compressed' : 'expanded'
  const destNameSuffix = isMin ? '.min' : ''

  return src('src/scss/' + baseName + '.scss')
    .pipe(sass({outputStyle}).on('error', sass.logError))
    .pipe(rename(baseName + destNameSuffix + '.css'))
    .pipe(dest(destDir + '/css'))
}

const processScssMain = () => {
  return processScss('main')
}

const processScssMainMin = () => {
  return processScss('main', true)
}

/* HTML */

const copyHtml = () => {
  return src('src/html/*')
    .pipe(dest(destDir))
}

/* Img */

const copyImg = () => {
  return src('src/img/*')
    .pipe(dest(destDir + '/img'))
}

exports.default = series(
  processJsMain,
  processJsMainMin,
  processJsChartSample,
  processJsChartSampleMin,
  processScssMain,
  processScssMainMin,
  copyHtml,
  copyImg
)
