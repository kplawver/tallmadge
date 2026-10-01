module.exports = function (eleventyConfig) {
  eleventyConfig.addPassthroughCopy({ "src/CNAME": "CNAME" });
  eleventyConfig.addPassthroughCopy({ "src/styles.css": "styles.css" });

  eleventyConfig.addShortcode("year", () => `${new Date().getFullYear()}`);

  return {
    templateFormats: ["njk", "md"],
    htmlTemplateEngine: "njk",
    dir: {
      input: "src",
      includes: "_includes",
      data: "_data",
      output: "_site",
    },
  };
};
