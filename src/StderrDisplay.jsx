import React from 'react';
import CodeMirrorEditor from 'react-code-mirror';
import CodeMirrorNim from './nimrod';
import ansiHTML from 'ansi-html';

ansiHTML.tags.open['0'] = 'color:#DCDCCC';

ansiHTML.tags.open['30'] = 'color:#DCDCCC';
ansiHTML.tags.open['31'] = 'color:#CC9393';
ansiHTML.tags.open['32'] = 'color:#7F9F7F';
ansiHTML.tags.open['33'] = 'color:#F0DFAF';
ansiHTML.tags.open['34'] = 'color:#8CD0D3';
ansiHTML.tags.open['35'] = 'color:#DC8CC3';
ansiHTML.tags.open['36'] = 'color:#93E0E3';
ansiHTML.tags.open['37'] = 'color:#DCDCCC';

ansiHTML.tags.open['40'] = 'color:#DCDCCC';
ansiHTML.tags.open['41'] = 'color:#CC9393';
ansiHTML.tags.open['42'] = 'color:#7F9F7F';
ansiHTML.tags.open['43'] = 'color:#F0DFAF';
ansiHTML.tags.open['44'] = 'color:#8CD0D3';
ansiHTML.tags.open['45'] = 'color:#DC8CC3';
ansiHTML.tags.open['46'] = 'color:#93E0E3';
ansiHTML.tags.open['47'] = 'color:#DCDCCC';

require('./CodeMirrorStyle.css');

const codeMirrorStyles = {
  position: 'absolute',
  width: '100%',
  height: '100%',
};

export default class StderrDisplay extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      text: '',
    };
  }

  static contextTypes = {
    workerEmitter: React.PropTypes.any,
  };

  componentDidMount() {
    this.context.workerEmitter.on('stderr', data => {
      this.setState({ text: this.state.text + ansiHTML(data) + '\n' });
    });
  }

  render() {
    return (
      <div
        style={{ background: 'rgb(38, 50, 56)', whiteSpace: 'pre', fontFamily: 'monospace', minWidth: '100%', height: '100%', position: 'absolute', paddingLeft: '4px', }}
        dangerouslySetInnerHTML={{ __html: this.state.text }}
      />
    );
  }
}
